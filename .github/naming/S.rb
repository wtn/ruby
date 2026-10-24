# DIAGNOSTIC ONLY (naming branch): the body of test_thread_name_set_before_start
10.times do |i|
  q = Thread::Queue.new
  t = Thread.new do
    q.pop
    File.read("/proc/self/task/#{Thread.current.native_thread_id}/comm").chomp
  end
  t.name = "name#{i}"
  q << true
  v = t.value
  abort "MISMATCH #{i}: #{v.inspect}" unless v == "name#{i}"
end
