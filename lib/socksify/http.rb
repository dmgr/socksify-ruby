=begin
    Copyright (C) 2007 Stephan Maka <stephan@spaceboyz.net>
    Copyright (C) 2011 Musy Bite <musybite@gmail.com>

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

require 'socksify'
require 'net/http'

module Net
  class HTTP
    def self.SocksProxy
      Class.new(self) do
        include SOCKSProxyDelta::InstanceMethods
        extend  SOCKSProxyDelta::ClassMethods
        # class << self
          @proxies = []
        # end
      end
    end

    module SOCKSProxyDelta
      module ClassMethods
        attr_reader :proxies
        # def proxies
        #   @proxies
        # end

        def add(socks_host, socks_port, socks_version)
          proxies.unshift [socks_host, socks_port, socks_version]
        end
      end

      module InstanceMethods
        if RUBY_VERSION[0..0] >= '2'
          def address
            self.class.proxies.reduce(@address) do |result, proxy|
              TCPSocket::SOCKSConnectionPeerAddress.new(*proxy, result)
            end
          end
        else
          def conn_address
            self.class.proxies.reduce(address) do |result, proxy|
              TCPSocket::SOCKSConnectionPeerAddress.new(*proxy, result)
            end
          end
        end
      end
    end
  end
end
