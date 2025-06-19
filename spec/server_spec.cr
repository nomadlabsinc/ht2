require "./spec_helper"

describe HT2::Server do
  describe "basic server functionality" do
    it "can create a server instance" do
      handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
        response.status = 200
        response.write("OK")
        response.close
      end

      # Generate test certificate files
      temp_key_file = "#{Dir.tempdir}/test_key_#{Random.rand(100000)}.pem"
      temp_cert_file = "#{Dir.tempdir}/test_cert_#{Random.rand(100000)}.pem"

      begin
        # Generate RSA key
        system("openssl genrsa -out #{temp_key_file} 2048 2>/dev/null")

        # Generate self-signed certificate
        system("openssl req -new -x509 -key #{temp_key_file} -out #{temp_cert_file} -days 1 -subj '/CN=localhost' 2>/dev/null")

        # Create TLS context
        tls_context = HT2::Server.create_tls_context(temp_cert_file, temp_key_file)

        # Create server instance
        server = HT2::Server.new("localhost", 0, handler, tls_context: tls_context)
        server.should_not be_nil

        # Clean up
        server.close
      ensure
        File.delete(temp_key_file) if File.exists?(temp_key_file)
        File.delete(temp_cert_file) if File.exists?(temp_cert_file)
      end
    end
  end

  describe "TLS context creation" do
    it "can create TLS context from certificate files" do
      # Generate test certificate files
      temp_key_file = "#{Dir.tempdir}/test_key_#{Random.rand(100000)}.pem"
      temp_cert_file = "#{Dir.tempdir}/test_cert_#{Random.rand(100000)}.pem"

      begin
        # Generate RSA key
        system("openssl genrsa -out #{temp_key_file} 2048 2>/dev/null")

        # Generate self-signed certificate
        system("openssl req -new -x509 -key #{temp_key_file} -out #{temp_cert_file} -days 1 -subj '/CN=localhost' 2>/dev/null")

        # Create TLS context
        context = HT2::Server.create_tls_context(temp_cert_file, temp_key_file)
        context.should_not be_nil
        context.should be_a(OpenSSL::SSL::Context::Server)
      ensure
        File.delete(temp_key_file) if File.exists?(temp_key_file)
        File.delete(temp_cert_file) if File.exists?(temp_cert_file)
      end
    end
  end
end
