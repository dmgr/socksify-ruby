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

class << Net::HTTP
  alias_method :HttpProxy, :Proxy

  def Proxy(*args)
    case uri = args[0]
    when Socksify::URI::InstanceMethods
      Class.new(self) do
        extend  SocksProxyClassMethods
        include SocksProxyInstanceMethods
        @proxy = uri
      end
    when URI
      if Socksify::URI::SOCKS_SCHEMES[uri.scheme]
        uri.dup.singleton_class.send(:include, Socksify::URI::InstanceMethods)
        Proxy(uri)
      else
        HttpProxy(uri.host, uri.port, uri.user, uri.password)
      end
    else
      HttpProxy(*args)
    end
  end

  module SocksProxyClassMethods
    attr_reader :proxy
  end

  module SocksProxyInstanceMethods
    if RUBY_VERSION[0..0] >= '2'
      def address
        Socksify::Host.new(@address, self.class.proxy)
      end
    else
      def conn_address
        Socksify::Host.new(address, self.class.proxy)
      end
    end
  end
end
