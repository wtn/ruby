#include "ruby.h"
#include "ruby/io.h"
#include "internal/error.h"

static VALUE
bug_syserr_new_path_in(VALUE self, VALUE func_name, VALUE errno_val, VALUE path)
{
    const char *fn = NIL_P(func_name) ? NULL : StringValueCStr(func_name);
    return rb_syserr_new_path_in(fn, NUM2INT(errno_val), path);
}

/*
 * Mirrors the body of `rb_sys_fail_on_write` in io.c (which is static and so
 * not callable from outside). Given an open IO and an errno value, set errno
 * and raise via the same `rb_syserr_fail_path` macro io.c uses. This exercises
 * the io-side error-reporting path on a real IO and demonstrates that an
 * errno value of 0 at the failure-handling site triggers `rb_bug` rather than
 * a clean SystemCallError.
 */
static VALUE
bug_io_fail_with_errno(VALUE self, VALUE io, VALUE errno_val)
{
    rb_io_t *fptr;
    int e = NUM2INT(errno_val);
    GetOpenFile(io, fptr);
    errno = e;
    rb_syserr_fail_path(e, rb_io_path(io));
    return Qnil; /* unreachable */
}

void
Init_syserr(VALUE klass)
{
    rb_define_singleton_method(klass, "syserr_new_path_in", bug_syserr_new_path_in, 3);
    rb_define_singleton_method(klass, "io_fail_with_errno", bug_io_fail_with_errno, 2);
}
