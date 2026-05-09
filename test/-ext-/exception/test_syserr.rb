# frozen_string_literal: false
require 'test/unit'
require '-test-/exception'

module Bug
  class Test_Syserr < Test::Unit::TestCase
    # Sanity check: with a real errno, rb_syserr_new_path_in returns the
    # matching Errno::* subclass instance.
    def test_real_errno_returns_errno_subclass
      exc = Bug::Exception.syserr_new_path_in("write", Errno::EPIPE::Errno, "/tmp/x")
      assert_kind_of Errno::EPIPE, exc
    end

    # Bug: rb_syserr_new_path_in calls rb_bug() when errno == 0 (error.c:3614 on
    # ruby_3_3 / 4017 on master). This kills the process.
    #
    # The intermediate I/O machinery can produce errno == 0 here without it
    # being a Ruby interpreter bug. rb_sys_fail_on_write (io.c) reads `errno`
    # at the failure-handling site, not at the failing syscall site, and an
    # intervening fiber-scheduler yield, mutex unlock, or libc helper can clobber
    # errno to 0 in between. The result is a process-killing rb_bug whose actual
    # cause is "we lost the errno on the way over", not an interpreter invariant
    # violation.
    #
    # The correct behavior is to return a generic SystemCallError carrying the
    # synthesized name (the same fallback `get_syserr` already provides for any
    # unrecognized errno via `E000`-style class synthesis).
    #
    # This test currently fails because the subprocess is aborted by rb_bug
    # before it can return.
    def test_errno_zero_does_not_rb_bug
      assert_normal_exit(<<~'RUBY', "rb_syserr_new_path_in(..., 0, ...) must not call rb_bug")
        require '-test-/exception'
        Bug::Exception.syserr_new_path_in("write", 0, "/tmp/x")
      RUBY
    end

    # Stronger form: the returned value should be a SystemCallError instance
    # (not just "process didn't die"). After the fix, this should hold.
    def test_errno_zero_returns_system_call_error
      assert_separately([], <<~'RUBY')
        require '-test-/exception'
        exc = Bug::Exception.syserr_new_path_in("write", 0, "/tmp/x")
        raise "expected SystemCallError, got #{exc.inspect}" unless exc.is_a?(SystemCallError)
      RUBY
    end

    # End-to-end through the io.c reporting machinery. `Bug::Exception.io_fail_with_errno`
    # mirrors the body of io.c's static `rb_sys_fail_on_write`: given a real IO
    # and an errno value, it sets errno and invokes the same `rb_syserr_fail_path`
    # macro io.c uses to construct the exception. This is as close as we can get
    # to driving the failure-reporting path through `IO#write` without modifying
    # io.c, since `rb_sys_fail_on_write` itself is static.
    #
    # Sanity: with errno = EPIPE, we get the expected Errno::EPIPE.
    def test_io_fail_with_real_errno_raises_errno_subclass
      require 'tempfile'
      Tempfile.create("syserr_test") do |f|
        assert_raise(Errno::EPIPE) do
          Bug::Exception.io_fail_with_errno(f, Errno::EPIPE::Errno)
        end
      end
    end

    # Bug: with errno = 0 at the failure-handling site, the io.c reporting path
    # rb_bugs and aborts the process. After the fix, it should raise a generic
    # SystemCallError instead, which `assert_normal_exit` will allow.
    def test_io_fail_with_errno_zero_does_not_rb_bug
      assert_normal_exit(<<~'RUBY', "io.c failure-reporting must not rb_bug on errno == 0")
        require '-test-/exception'
        require 'tempfile'
        Tempfile.create("syserr_test") do |f|
          begin
            Bug::Exception.io_fail_with_errno(f, 0)
          rescue SystemCallError
            # expected after fix
          end
        end
      RUBY
    end
  end
end
