require "rails_helper"

RSpec.describe PatchCi::BucketCase do
  # expr is a bare literal, not a column - this pins the CASE's own boundary
  # logic without needing a table
  def evaluate(value, buckets, operator:, null_check: "false")
    sql = described_class.sql(buckets, expr: value.nil? ? "NULL" : value.to_s,
                              operator: operator, bound_sql: ->(bound) { bound.to_s },
                              null_check: null_check)
    ActiveRecord::Base.connection.select_value("SELECT #{sql}")
  end

  it "buckets with < : the bound itself falls into the next band, not this one" do
    buckets = [ [ "small", 5 ], [ "big", nil ] ]
    expect(evaluate(4, buckets, operator: "<")).to eq("small")
    expect(evaluate(5, buckets, operator: "<")).to eq("big")
  end

  it "buckets with > : the bound itself falls into the next band, not this one" do
    buckets = [ [ "recent", 5 ], [ "old", nil ] ]
    expect(evaluate(6, buckets, operator: ">")).to eq("recent")
    expect(evaluate(5, buckets, operator: ">")).to eq("old")
  end

  it "returns unknown when the null check is true, regardless of value" do
    buckets = [ [ "small", 5 ], [ "big", nil ] ]
    expect(evaluate(1, buckets, operator: "<", null_check: "true")).to eq("unknown")
  end
end
