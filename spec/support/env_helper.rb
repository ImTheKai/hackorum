module EnvHelper
  def with_env(values)
    saved = values.keys.to_h { |k| [k, ENV[k]] }
    values.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end

RSpec.configure do |config|
  config.include EnvHelper
end
