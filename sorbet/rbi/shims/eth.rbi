# typed: false

module Eth
  module Util
    def self.keccak256(data); end
    def self.public_key_to_address(key); end
  end

  class Key
    def initialize(priv: nil); end
    def address; end
    def private_hex; end
    def sign(data); end
    def self.personal_recover(data, signature); end
  end
end
