=begin
= $RCSfile$ -- Ruby-space definitions that completes C-space funcs for SSL

= Info
  'OpenSSL for Ruby 2' project
  Copyright (C) 2001 GOTOU YUUZOU <gotoyuzo@notwork.org>
  All rights reserved.

= Licence
  This program is licensed under the same licence as Ruby.
  (See the file 'LICENCE'.)

= Version
  $Id$
=end

require "openssl/buffering"
require "io/nonblock"

module OpenSSL
  module SSL
    class SSLContext
      DEFAULT_PARAMS = {
        ssl_version: "SSLv23",
        verify_mode: OpenSSL::SSL::VERIFY_PEER,
        ciphers: %w{
          ECDHE-ECDSA-AES128-GCM-SHA256
          ECDHE-RSA-AES128-GCM-SHA256
          ECDHE-ECDSA-AES256-GCM-SHA384
          ECDHE-RSA-AES256-GCM-SHA384
          DHE-RSA-AES128-GCM-SHA256
          DHE-DSS-AES128-GCM-SHA256
          DHE-RSA-AES256-GCM-SHA384
          DHE-DSS-AES256-GCM-SHA384
          ECDHE-ECDSA-AES128-SHA256
          ECDHE-RSA-AES128-SHA256
          ECDHE-ECDSA-AES128-SHA
          ECDHE-RSA-AES128-SHA
          ECDHE-ECDSA-AES256-SHA384
          ECDHE-RSA-AES256-SHA384
          ECDHE-ECDSA-AES256-SHA
          ECDHE-RSA-AES256-SHA
          DHE-RSA-AES128-SHA256
          DHE-RSA-AES256-SHA256
          DHE-RSA-AES128-SHA
          DHE-RSA-AES256-SHA
          DHE-DSS-AES128-SHA256
          DHE-DSS-AES256-SHA256
          DHE-DSS-AES128-SHA
          DHE-DSS-AES256-SHA
          AES128-GCM-SHA256
          AES256-GCM-SHA384
          AES128-SHA256
          AES256-SHA256
          AES128-SHA
          AES256-SHA
          ECDHE-ECDSA-RC4-SHA
          ECDHE-RSA-RC4-SHA
          RC4-SHA
        }.join(":"),
        options: -> {
          opts = OpenSSL::SSL::OP_ALL
          opts &= ~OpenSSL::SSL::OP_DONT_INSERT_EMPTY_FRAGMENTS if defined?(OpenSSL::SSL::OP_DONT_INSERT_EMPTY_FRAGMENTS)
          opts |= OpenSSL::SSL::OP_NO_COMPRESSION if defined?(OpenSSL::SSL::OP_NO_COMPRESSION)
          opts |= OpenSSL::SSL::OP_NO_SSLv2 if defined?(OpenSSL::SSL::OP_NO_SSLv2)
          opts |= OpenSSL::SSL::OP_NO_SSLv3 if defined?(OpenSSL::SSL::OP_NO_SSLv3)
          opts
        }.call
      }

      DEFAULT_CERT_STORE = OpenSSL::X509::Store.new
      DEFAULT_CERT_STORE.set_default_paths
      if defined?(OpenSSL::X509::V_FLAG_CRL_CHECK_ALL)
        DEFAULT_CERT_STORE.flags = OpenSSL::X509::V_FLAG_CRL_CHECK_ALL
      end

      INIT_VARS = ["cert", "key", "client_ca", "ca_file", "ca_path",
        "timeout", "verify_mode", "verify_depth", "renegotiation_cb",
        "verify_callback", "options", "cert_store", "extra_chain_cert",
        "client_cert_cb", "session_id_context",
        "session_get_cb", "session_new_cb", "session_remove_cb",
        "tmp_ecdh_callback", "servername_cb", "npn_protocols",
        "alpn_protocols", "alpn_select_cb",
        "npn_select_cb"].map { |x| "@#{x}" }

      # call-seq:
      #    SSLContext.new => ctx
      #    SSLContext.new(:TLSv1) => ctx
      #    SSLContext.new("SSLv23_client") => ctx
      #
      # You can get a list of valid methods with OpenSSL::SSL::SSLContext::METHODS
      def initialize(version = nil)
        INIT_VARS.each { |v| instance_variable_set v, nil }
        @tmp_dh_callback = OpenSSL::PKey::DEFAULT_TMP_DH_CALLBACK
        return unless version
        self.ssl_version = version
      end

      ##
      # Sets the parameters for this SSL context to the values in +params+.
      # The keys in +params+ must be assignment methods on SSLContext.
      #
      # If the verify_mode is not VERIFY_NONE and ca_file, ca_path and
      # cert_store are not set then the system default certificate store is
      # used.

      def set_params(params={})
        params = DEFAULT_PARAMS.merge(params)
        params.each{|name, value| self.__send__("#{name}=", value) }
        if self.verify_mode != OpenSSL::SSL::VERIFY_NONE
          unless self.ca_file or self.ca_path or self.cert_store
            self.cert_store = DEFAULT_CERT_STORE
          end
        end
        return params
      end

      def tmp_dh_callback=(value)
        @tmp_dh_callback = value || OpenSSL::PKey::DEFAULT_TMP_DH_CALLBACK
      end
    end

    module SocketForwarder
      def addr
        to_io.addr
      end

      def peeraddr
        to_io.peeraddr
      end

      def setsockopt(level, optname, optval)
        to_io.setsockopt(level, optname, optval)
      end

      def getsockopt(level, optname)
        to_io.getsockopt(level, optname)
      end

      def fcntl(*args)
        to_io.fcntl(*args)
      end

      def closed?
        to_io.closed?
      end

      def do_not_reverse_lookup=(flag)
        to_io.do_not_reverse_lookup = flag
      end
    end

    module Nonblock
      def initialize(*args)
        @io.nonblock = true if @io.respond_to?(:nonblock=)
        super
      end
    end

    def verify_certificate_identity(cert, hostname)
      should_verify_common_name = true
      cert.extensions.each{|ext|
        next if ext.oid != "subjectAltName"
        ostr = OpenSSL::ASN1.decode(ext.to_der).value.last
        sequence = OpenSSL::ASN1.decode(ostr.value)
        sequence.value.each{|san|
          case san.tag
          when 2 # dNSName in GeneralName (RFC5280)
            should_verify_common_name = false
            return true if verify_hostname(hostname, san.value)
          when 7 # iPAddress in GeneralName (RFC5280)
            should_verify_common_name = false
            # follows GENERAL_NAME_print() in x509v3/v3_alt.c
            if san.value.size == 4
              return true if san.value.unpack('C*').join('.') == hostname
            elsif san.value.size == 16
              return true if san.value.unpack('n*').map { |e| sprintf("%X", e) }.join(':') == hostname
            end
          end
        }
      }
      if should_verify_common_name
        cert.subject.to_a.each{|oid, value|
          if oid == "CN"
            return true if verify_hostname(hostname, value)
          end
        }
      end
      return false
    end
    module_function :verify_certificate_identity

    def verify_hostname(hostname, san) # :nodoc:
      # RFC 5280, IA5String is limited to the set of ASCII characters
      return false unless san.ascii_only?
      return false unless hostname.ascii_only?

      # See RFC 6125, section 6.4.1
      # Matching is case-insensitive.
      san_parts = san.downcase.split(".")

      # TODO: this behavior should probably be more strict
      return san == hostname if san_parts.size < 2

      # Matching is case-insensitive.
      host_parts = hostname.downcase.split(".")

      # RFC 6125, section 6.4.3, subitem 2.
      # If the wildcard character is the only character of the left-most
      # label in the presented identifier, the client SHOULD NOT compare
      # against anything but the left-most label of the reference
      # identifier (e.g., *.example.com would match foo.example.com but
      # not bar.foo.example.com or example.com).
      return false unless san_parts.size == host_parts.size

      # RFC 6125, section 6.4.3, subitem 1.
      # The client SHOULD NOT attempt to match a presented identifier in
      # which the wildcard character comprises a label other than the
      # left-most label (e.g., do not match bar.*.example.net).
      return false unless verify_wildcard(host_parts.shift, san_parts.shift)

      san_parts.join(".") == host_parts.join(".")
    end
    module_function :verify_hostname

    def verify_wildcard(domain_component, san_component) # :nodoc:
      parts = san_component.split("*", -1)

      return false if parts.size > 2
      return san_component == domain_component if parts.size == 1

      # RFC 6125, section 6.4.3, subitem 3.
      # The client SHOULD NOT attempt to match a presented identifier
      # where the wildcard character is embedded within an A-label or
      # U-label of an internationalized domain name.
      return false if domain_component.start_with?("xn--") && san_component != "*"

      parts[0].length + parts[1].length < domain_component.length &&
      domain_component.start_with?(parts[0]) &&
      domain_component.end_with?(parts[1])
    end
    module_function :verify_wildcard

    class SSLSocket
      include Buffering
      include SocketForwarder
      include Nonblock

      ##
      # Perform hostname verification after an SSL connection is established
      #
      # This method MUST be called after calling #connect to ensure that the
      # hostname of a remote peer has been verified.
      def post_connection_check(hostname)
        if peer_cert.nil?
          msg = "Peer verification enabled, but no certificate received."
          if using_anon_cipher?
            msg += " Anonymous cipher suite #{cipher[0]} was negotiated. Anonymous suites must be disabled to use peer verification."
          end
          raise SSLError, msg
        end

        unless OpenSSL::SSL.verify_certificate_identity(peer_cert, hostname)
          raise SSLError, "hostname \"#{hostname}\" does not match the server certificate"
        end
        return true
      end

      def session
        SSL::Session.new(self)
      rescue SSL::Session::SessionError
        nil
      end

      private

      def using_anon_cipher?
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.ciphers = "aNULL"
        ctx.ciphers.include?(cipher)
      end
    end

    ##
    # SSLServer represents a TCP/IP server socket with Secure Sockets Layer.
    class SSLServer
      include SocketForwarder
      # When true then #accept works exactly the same as TCPServer#accept
      attr_accessor :start_immediately

      # Creates a new instance of SSLServer.
      # * +srv+ is an instance of TCPServer.
      # * +ctx+ is an instance of OpenSSL::SSL::SSLContext.
      def initialize(svr, ctx)
        @svr = svr
        @ctx = ctx
        unless ctx.session_id_context
          # see #6137 - session id may not exceed 32 bytes
          prng = ::Random.new($0.hash)
          session_id = prng.bytes(16).unpack('H*')[0]
          @ctx.session_id_context = session_id
        end
        @start_immediately = true
      end

      # Returns the TCPServer passed to the SSLServer when initialized.
      def to_io
        @svr
      end

      # See TCPServer#listen for details.
      def listen(backlog=5)
        @svr.listen(backlog)
      end

      # See BasicSocket#shutdown for details.
      def shutdown(how=Socket::SHUT_RDWR)
        @svr.shutdown(how)
      end

      # Works similar to TCPServer#accept.
      def accept
        # Socket#accept returns [socket, addrinfo].
        # TCPServer#accept returns a socket.
        # The following comma strips addrinfo.
        sock, = @svr.accept
        begin
          ssl = OpenSSL::SSL::SSLSocket.new(sock, @ctx)
          ssl.sync_close = true
          ssl.accept if @start_immediately
          ssl
        rescue Exception => ex
          if ssl
            ssl.close
          else
            sock.close
          end
          raise ex
        end
      end

      # See IO#close for details.
      def close
        @svr.close
      end
    end
  end
end
