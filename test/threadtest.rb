#!/usr/bin/ruby


class Test
  
  def start
    return @start
  end
  
  def initialize
    @result_buffer = []
    @result_mutex = Mutex.new
      
    @signaller = Mutex.new
    
    @start = Time.now.to_f
    
    @signaller.lock
    start_idler_thread
  end
  
  def start_idler_thread
    @idler_thread = Thread.new do
      n = 1
      while true
        n+=1
        if @signaller.try_lock
          print Time.now.to_f - @start," ", Thread.current.inspect,  " Exiting ",n,"\n"
          Thread.exit 
        else
          print Time.now.to_f - @start, " ", Thread.current.inspect, " Idling ", n,"\n"
        end
        Thread.pass
      end
     end
     sleep 0.01
  end
  
  
  def do_the_job
    print Time.now.to_f-@start, " Doing the job\n"
    
    print Time.now.to_f-@start, " Before signalling idler\n"
    @signaller.unlock
    print Time.now.to_f-@start, " After signalling idler\n"
    
    print Time.now.to_f-@start, " Before joining idler\n"
    @idler_thread.join
    print Time.now.to_f-@start, " After joining idler\n"
    inspect = @idler_thread.inspect
    @idler_thread = nil
    @signaller.lock    
        
    my_result = wait_for_result
    

    start_idler_thread
    
    return my_result, inspect
  end

  def wait_for_result
    
    start_result_thread
    return_val = nil
    
    while true
    
      unless return_val == nil
        stop_result_thread
        return return_val
      end
      
      @result_mutex.synchronize do
        return_val = Time.now.to_f-@start, " Returning\n" if @result == 5  
      end
          
    end
    
    stop_result_thread
  end
  
  def stop_result_thread
    @result_thread.exit
  end
  
  def start_result_thread
    @result_thread = Thread.new do
      while true
        @result_mutex.synchronize do
          @result = Random.rand(1..10)
        end
      end
    end
    
  end
      
end




my_class = Test.new

while true
  print Time.now.to_f-my_class.start, " Before calling\n"
  value = my_class.do_the_job
  print value,"\n"
  print Time.now.to_f-my_class.start, " After calling\n"
  sleep 0.01
end
