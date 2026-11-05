# typed: strict
# frozen_string_literal: true

require 'ipaddr'

module AutoHCK
  module Models
    # An existing, promoted DC. Its disk and NVRAM remain writable across sessions.
    class DomainController < T::Struct
      extend T::Sig
      extend JsonHelper

      const :name, String
      const :image, String
      const :nvram, String
      const :uuid, String
      const :mac, String
      const :ip, String
      const :domain, String
      const :cpus, Integer, default: 4
      const :memory_gb, Integer, default: 8
      const :readiness_timeout, Integer, default: 600
      const :winrm_port, Integer, default: 5985

      sig { void }
      def validate!
        validate_identity
        validate_paths
        validate_ip
        raise InvalidConfigFile, 'Invalid DC WinRM port' unless (1..65_535).cover?(winrm_port)
        return if cpus.positive? && memory_gb.positive? && readiness_timeout.positive?

        raise InvalidConfigFile, 'DC CPU count, memory and readiness timeout must be positive'
      end

      private

      sig { void }
      def validate_ip
        address = IPAddr.new(ip)
        reserved = %w[192.168.100.0 192.168.100.1 192.168.100.100 192.168.100.255]
        return if address.ipv4? && address.to_s == ip &&
                  IPAddr.new('192.168.100.0/24').include?(address) && !reserved.include?(ip)

        raise InvalidConfigFile, 'DC IP must be an available host address on br_ctrl (192.168.100.0/24)'
      rescue IPAddr::InvalidAddressError
        raise InvalidConfigFile, 'DC IP must be an IPv4 address on br_ctrl'
      end

      sig { void }
      def validate_identity
        raise InvalidConfigFile, 'Invalid DC hostname' unless /\A[a-zA-Z0-9][a-zA-Z0-9-]{0,14}\z/.match?(name)
        unless /\A[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+\z/.match?(domain)
          raise InvalidConfigFile, 'DC domain must be a DNS domain name'
        end
        unless /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i.match?(uuid)
          raise InvalidConfigFile, 'Invalid DC UUID'
        end
        return if /\A[0-9a-f][02468ace](?::[0-9a-f]{2}){5}\z/i.match?(mac)

        raise InvalidConfigFile, 'DC MAC must be a unicast MAC address'
      end

      sig { void }
      def validate_paths
        [image, nvram].each do |path|
          unless Pathname.new(path).absolute? && !path.match?(/[\s,]/)
            raise InvalidConfigFile, 'DC image and NVRAM require absolute paths without whitespace or commas'
          end
        end
        raise InvalidConfigFile, 'DC image and NVRAM must be different files' if image == nvram
      end
    end
  end
end
