require 'rails_helper'

RSpec.describe Gmail::SendClient do
  let(:identity) { create(:identity, access_token: 'tok') }
  let(:rfc822)   { "From: x@y\r\n\r\nbody" }

  def stub_response(code:, body: '')
    res = double('Net::HTTPResponse', code: code.to_s, body: body)
    http = double('Net::HTTP')
    allow(http).to receive(:request).and_return(res)
    allow(Net::HTTP).to receive(:start).and_yield(http)
    res
  end

  it 'returns parsed JSON on 200' do
    stub_response(code: 200, body: '{"id":"abc"}')
    expect(described_class.send_raw(identity, rfc822)).to eq({"id" => "abc"})
  end

  it 'raises AuthRevokedError on 401' do
    stub_response(code: 401, body: 'unauthorized')
    expect { described_class.send_raw(identity, rfc822) }
      .to raise_error(Gmail::AuthRevokedError)
  end

  it 'raises AuthRevokedError on 403' do
    stub_response(code: 403, body: 'forbidden')
    expect { described_class.send_raw(identity, rfc822) }
      .to raise_error(Gmail::AuthRevokedError)
  end

  it 'raises PermanentError on other 4xx' do
    stub_response(code: 400, body: 'bad')
    expect { described_class.send_raw(identity, rfc822) }
      .to raise_error(Gmail::PermanentError)
  end

  it 'raises TransientError on 5xx' do
    stub_response(code: 503, body: 'down')
    expect { described_class.send_raw(identity, rfc822) }
      .to raise_error(Gmail::TransientError)
  end

  it 'maps Net::ReadTimeout to TransientError' do
    http = double('Net::HTTP')
    allow(http).to receive(:request).and_raise(Net::ReadTimeout.new('timeout'))
    allow(Net::HTTP).to receive(:start).and_yield(http)
    expect { described_class.send_raw(identity, rfc822) }
      .to raise_error(Gmail::TransientError, /network error: Net::ReadTimeout/)
  end

  it 'maps SocketError to TransientError' do
    http = double('Net::HTTP')
    allow(http).to receive(:request).and_raise(SocketError.new('dns'))
    allow(Net::HTTP).to receive(:start).and_yield(http)
    expect { described_class.send_raw(identity, rfc822) }
      .to raise_error(Gmail::TransientError, /network error: SocketError/)
  end

  it 'sends base64url-encoded raw, Bearer auth header, JSON content type' do
    captured = nil
    res = double('Net::HTTPResponse', code: '200', body: '{}')
    http = double('Net::HTTP')
    allow(http).to receive(:request) { |req| captured = req; res }
    allow(Net::HTTP).to receive(:start).and_yield(http)
    described_class.send_raw(identity, rfc822)
    expect(captured["Authorization"]).to eq('Bearer tok')
    expect(captured["Content-Type"]).to eq('application/json')
    body = JSON.parse(captured.body)
    expect(Base64.urlsafe_decode64(body['raw'])).to eq(rfc822)
  end
end
