# frozen_string_literal: true
# encoding: us-ascii
=begin
  Copyright (C) 2007 Stephan Maka <stephan@spaceboyz.net>

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
=end

require 'socket'
require 'resolv'
require 'socksify/debug'

class SOCKSError < RuntimeError
  def initialize(msg)
    Socksify::debug_error("#{self.class}: #{msg}")
    super
  end

  class ServerFailure < SOCKSError
    def initialize
      super("general SOCKS server failure")
    end
  end
  class NotAllowed < SOCKSError
    def initialize
      super("connection not allowed by ruleset")
    end
  end
  class NetworkUnreachable < SOCKSError
    def initialize
      super("Network unreachable")
    end
  end
  class HostUnreachable < SOCKSError
    def initialize
      super("Host unreachable")
    end
  end
  class ConnectionRefused < SOCKSError
    def initialize
      super("Connection refused")
    end
  end
  class TTLExpired < SOCKSError
    def initialize
      super("TTL expired")
    end
  end
  class CommandNotSupported < SOCKSError
    def initialize
      super("Command not supported")
    end
  end
  class AddressTypeNotSupported < SOCKSError
    def initialize
      super("Address type not supported")
    end
  end

  def self.for_response_code(code)
    case code
    when 1
      ServerFailure
    when 2
      NotAllowed
    when 3
      NetworkUnreachable
    when 4
      HostUnreachable
    when 5
      ConnectionRefused
    when 6
      TTLExpired
    when 7
      CommandNotSupported
    when 8
      AddressTypeNotSupported
    else
      self
    end
  end
end

module Socksify
  class URI < URI::Generic
    SOCKS_SCHEMES = {
      'socks'  => '5',
      'socks4' => '4',
      'socks5' => '5'
    }

    module InstanceMethods
      attr_writer :version

      def version
        @version || SOCKS_SCHEMES[scheme] || '5'
      end
    end

    module ClassMethods
      def build(args)
        uri = super
        uri.scheme = "socks#{uri.version}"
        uri
      end
    end

    include InstanceMethods
    extend  ClassMethods
  end

  class Host < String
    attr_reader :socks, :destination_host

    def initialize(host, *socks_args)
      super @destination_host = host
      @socks =
        case socks_args[0]
        when URI
          socks_args[0]
        else
          URI.build host: socks_args[0], port: socks_args[1], version: socks_args[2]
        end
    end

    def inspect
      "#{self} (via #{proxy_chain.join ' via '})"
    end

    def proxy_chain
      if @destination_host.is_a?(Host)
        @destination_host.proxy_chain
      else
        []
      end.unshift(socks)
    end
  end
end

class TCPSocket
  alias initialize_tcp initialize

  # See http://tools.ietf.org/html/rfc1928
  def initialize(host=nil, port=0, local_host=nil, local_port=nil)
    if host.is_a?(Socksify::Host)
    # if socks_server and socks_port and not socks_ignores.include?(host)
      Socksify::debug_notice "Connecting to socks#{host.socks.version}://#{host.socks.host}:#{host.socks.port}"
      initialize_tcp(host.socks.host, host.socks.port)
      socks_authenticate(host.socks) if host.socks.version == '5'
      socks_server = nil

      while host.destination_host.is_a?(Socksify::Host)
        proxy = host.destination_host
        socks_connect(proxy.socks.host, proxy.socks.port, host)
        host = proxy
      end
      socks_connect(host, port, host)
    else
      Socksify::debug_notice "Connecting directly to #{host}:#{port}"
      initialize_tcp(host, port, local_host, local_port)
      Socksify::debug_debug "Connected to #{host}:#{port}"
    end
  end

  # Authentication
  def socks_authenticate(socks)
    if socks.user || socks.password
      Socksify::debug_debug "Sending username/password authentication"
      write "\005\001\002"
    else
      Socksify::debug_debug "Sending no authentication"
      write "\005\001\000"
    end
    Socksify::debug_debug "Waiting for authentication reply"
    auth_reply = recv(2)
    if auth_reply.empty?
      raise SOCKSError.new("Server doesn't reply authentication")
    end
    if auth_reply[0..0] != "\004" and auth_reply[0..0] != "\005"
      raise SOCKSError.new("SOCKS version #{auth_reply[0..0]} not supported")
    end
    if socks.user || socks.password
      if auth_reply[1..1] != "\002"
        raise SOCKSError.new("SOCKS authentication method #{auth_reply[1..1]} neither requested nor supported")
      end
      auth = "\001"
      auth += socks.user.to_s.length.chr
      auth += socks.user.to_s
      auth += socks.password.to_s.length.chr
      auth += socks.password.to_s
      write auth
      auth_reply = recv(2)
      if auth_reply[1..1] != "\000"
        raise SOCKSError.new("SOCKS authentication failed")
      end
    else
      if auth_reply[1..1] != "\000"
        raise SOCKSError.new("SOCKS authentication method #{auth_reply[1..1]} neither requested nor supported")
      end
    end
  end

  def socks_connect(host, port, socks_server)
    socks_version = socks_server.socks.version
    Socksify::debug_debug "Connecting to #{host}:#{port} via socks#{socks_version}://#{socks_server.socks.host}:#{socks_server.socks.port}..."
    port = Socket.getservbyname(port) if port.is_a?(String)
    req = String.new
    Socksify::debug_debug "Sending destination address"
    req << (socks_version == '5' ? "\005" : "\004")
    Socksify::debug_debug socks_version.unpack "H*"
    req << "\001"
    req << (socks_version == '5' ? "\000" : [port].pack('n'))

    if socks_version == "4"
      Socksify::debug_debug "DNS leak!"
      host = Resolv::DNS.new.getaddress(host).to_s
    end
    if host =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/  # to IPv4 address
      req << "\001" if socks_version == '5'
      _ip = [$1.to_i,
             $2.to_i,
             $3.to_i,
             $4.to_i
            ].pack('CCCC')
      req << _ip
    elsif host =~ /^[:0-9a-f]+$/  # to IPv6 address
      raise "TCP/IPv6 over SOCKS is not yet supported (inet_pton missing in Ruby & not supported by Tor"
      req << "\004"
    else
      Socksify::debug_notice "Resolving #{host} via SOCKS"
      if socks_version == '5'
        req << "\003" << [host.size].pack('C') << host
      else
        req << "\000\000\000\001"
        req << "\007\000"
        req << host
        req << "\000"
      end
    end
    req << (socks_version == '5' ? [port].pack('n') : "\000")
    write req

    socks_receive_reply(socks_version)
    Socksify::debug_notice "Connected to #{host}:#{port} via socks#{socks_version}://#{socks_server.socks.host}:#{socks_server.socks.port}"
  end

  # returns [bind_addr: String, bind_port: Fixnum]
  def socks_receive_reply(socks_version)
    Socksify::debug_debug "Waiting for SOCKS reply"
    if socks_version == '5'
      connect_reply = recv(4)
      if connect_reply.empty?
        raise SOCKSError.new("Server doesn't reply")
      end
      Socksify::debug_debug connect_reply.unpack "H*"
      if connect_reply[0..0] != "\005"
        raise SOCKSError.new("SOCKS version #{connect_reply[0..0]} is not 5")
      end
      if connect_reply[1..1] != "\000"
        raise SOCKSError.for_response_code(connect_reply.bytes.to_a[1])
      end
      Socksify::debug_debug "Waiting for bind_addr"
      bind_addr_len = case connect_reply[3..3]
                      when "\001"
                        4
                      when "\003"
                        recv(1).bytes.first
                      when "\004"
                        16
                      else
                        raise SOCKSError.for_response_code(connect_reply.bytes.to_a[3])
                      end
      bind_addr_s = recv(bind_addr_len)
      bind_addr = case connect_reply[3..3]
                  when "\001"
                    bind_addr_s.bytes.to_a.join('.')
                  when "\003"
                    bind_addr_s
                  when "\004" # Untested!
                    i = 0
                    ip6 = ""
                    bind_addr_s.each_byte do |b|
                      if i > 0 and i % 2 == 0
                        ip6 += ":"
                      end
                      i += 1

                      ip6 += b.to_s(16).rjust(2, '0')
                    end
                  end
      bind_port = recv(bind_addr_len + 2)
      [bind_addr, bind_port.unpack('n')]
    else
      connect_reply = recv(8)
      unless connect_reply[0] == "\000" and connect_reply[1] == "\x5A"
        Socksify::debug_debug connect_reply.unpack 'H'
        raise SOCKSError.new("Failed while connecting througth socks")
      end
    end
  end
end

module Socksify
  def self.resolve(host)
    s = TCPSocket.new

    begin
      req = String.new
      Socksify::debug_debug "Sending hostname to resolve: #{host}"
      req << "\005"
      if host =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/  # to IPv4 address
        req << "\xF1\000\001" + [$1.to_i,
                                  $2.to_i,
                                  $3.to_i,
                                  $4.to_i
                                 ].pack('CCCC')
      elsif host =~ /^[:0-9a-f]+$/  # to IPv6 address
        raise "TCP/IPv6 over SOCKS is not yet supported (inet_pton missing in Ruby & not supported by Tor"
        req << "\004"
      else                          # to hostname
        req << "\xF0\000\003" + [host.size].pack('C') + host
      end
      req << [0].pack('n')  # Port
      s.write req

      addr, _port = s.socks_receive_reply
      Socksify::debug_notice "Resolved #{host} as #{addr} over SOCKS"
      addr
    ensure
      s.close
    end
  end

  # def self.proxy(server, port)
  #   default_server = TCPSocket::socks_server
  #   default_port = TCPSocket::socks_port
  #   begin
  #     TCPSocket::socks_server = server
  #     TCPSocket::socks_port = port
  #     yield
  #   ensure
  #     TCPSocket::socks_server = default_server
  #     TCPSocket::socks_port = default_port
  #   end
  # end
end
