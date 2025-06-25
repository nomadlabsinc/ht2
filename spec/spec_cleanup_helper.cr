# Helper to ensure proper cleanup of servers in tests
module SpecCleanupHelper
  @@active_servers = [] of HT2::Server
  @@active_fibers = [] of Fiber

  def self.register_server(server : HT2::Server)
    @@active_servers << server
  end

  def self.register_fiber(fiber : Fiber)
    @@active_fibers << fiber
  end

  def self.cleanup_all
    @@active_servers.each do |server|
      server.close rescue nil
    end
    @@active_servers.clear

    # Wait briefly for fibers to finish
    sleep 10.milliseconds
  end
end

# Ensure cleanup after each spec
Spec.after_each do
  SpecCleanupHelper.cleanup_all
end

# Ensure cleanup at exit
at_exit do
  SpecCleanupHelper.cleanup_all
end
