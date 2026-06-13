require "webmock/rspec"

WebMock.allow_net_connect!

RSpec.configure do |config|
  config.before(:each, :webmock) do
    WebMock.disable_net_connect!
  end
  config.after(:each, :webmock) { WebMock.allow_net_connect! }
end
