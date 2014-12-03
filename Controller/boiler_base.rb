class Switch
  attr_accessor :name, :id, :location, :do_tests
  attr_reader :state

  def initialize(name, location, master_id, slave_id, do_tests)
    @name = name
    @master_id = master_id
    @slave_id = slave_id 
    @location = location
    @do_tests = do_tests
    
    @state="unknown"

    !@do_tests and off
    @state = "off"
  end

  def close  
    off
  end

  def open
    on
  end
  
  def on
    if @state != "on"
      !@do_tests and write_path("1")
      @state = "on"
    end
  end

  def off
    if @state != "off"
      !@do_tests and write_path("0")
      @state = "off"
    end
  end
end
end