# frozen_string_literal: true

# Demo client: issues a fake SPT and retries the 402.
# Internally, create_spt would call Link / spend-request issuance.
#
#   bundle exec ruby app.rb
#   bundle exec ruby client.rb

require "mpp-rb"
require "json"

url = ARGV[0] || "http://localhost:4567/paid"

transport = Mpp::Client::Transport.new(
  methods: [
    Mpp::Methods::Stripe::ClientMethod.new(
      create_spt: ->(amount:, currency:, network_id:, payment_method:) {
        warn "issuing demo SPT for #{amount} #{currency} to #{network_id}"
        "spt_demo_#{Time.now.to_i}"
      }
    )
  ]
)

response = transport.get(url)
warn "#{response.code} #{response.message}"
warn "Payment-Receipt: #{response["Payment-Receipt"]}" if response["Payment-Receipt"]
puts response.body
exit(1) unless response.code.to_i.between?(200, 299)
