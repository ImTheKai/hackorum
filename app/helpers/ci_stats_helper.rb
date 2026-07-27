module CiStatsHelper
  # stacking order is load-bearing: with the neutral between success and
  # tests failed, the worst adjacent CVD pair passes (dE 10.9 deutan) where the
  # semantic order fails it (1.7). Do not "fix" this to read more naturally.
  STATUS_BANDS = %w[success cancelled tests_failed build_failed infra_error].freeze
  STATUS_COLORS = {
    "success" => "var(--ci-chart-success)",
    "cancelled" => "var(--ci-chart-cancelled)",
    "tests_failed" => "var(--ci-chart-testsfail)",
    "build_failed" => "var(--ci-chart-buildfail)",
    "infra_error" => "var(--ci-chart-infra)"
  }.freeze

  SLOTS = (1..4).map { |n| "var(--ci-chart-slot#{n})" }.freeze
  ORDINAL = (1..5).map { |n| "var(--ci-chart-ord#{n})" }.freeze

  VEGA_LITE_SCHEMA = "https://vega.github.io/schema/vega-lite/v5.json".freeze

  # chart rows carry the bucket as UTC ISO; the table twin keeps the Time for l()
  def ci_bucket_points(rows, value_key)
    rows.map { |row| { "bucket" => row[:bucket].iso8601, "value" => row[value_key] } }
  end

  # recessive chrome, once: solid hairline grid one shade off the surface, no
  # dashes (a dashed grid reads as a threshold), text in ink tokens
  def ci_chart_config
    {
      background: "transparent",
      axis: { grid: true, gridColor: "var(--color-chart-border)", gridWidth: 1,
              gridDash: [], domainColor: "var(--color-chart-border)",
              tickColor: "var(--color-chart-border)",
              labelColor: "var(--color-chart-text)",
              titleColor: "var(--color-chart-text)" },
      legend: { labelColor: "var(--color-chart-text)",
                titleColor: "var(--color-chart-text)" },
      view: { stroke: nil }
    }
  end

  # width: nil for a facet outer spec - vega-lite rejects "container" there,
  # the nested "spec" carries its own fixed width instead
  def ci_chart_base(values, height: 220, width: "container")
    { "$schema": VEGA_LITE_SCHEMA, data: { values: values }, config: ci_chart_config }.tap do |base|
      base[:width] = width unless width.nil?
      base[:height] = height unless height.nil?
    end
  end

  # x is temporal unless told otherwise: the corpus panel buckets by year, which
  # is a number on the axis, not a date
  #
  # buckets are UTC days from date_trunc; a local-time axis would slide them off
  # the table twin for any reader outside UTC
  def ci_x_encoding(field, title, temporal: true, sort: nil)
    { field: field, type: temporal ? "temporal" : "ordinal", title: title,
      axis: { labelAngle: 0 } }.tap do |e|
      e[:scale] = { type: "utc" } if temporal
      e[:sort] = sort if sort
    end
  end

  # field + domain/range + top legend: the one block every series-colored
  # builder needs, so it is not re-typed four times
  def ci_series_color(field, series)
    raise ArgumentError, "#{series.size} series exceeds #{SLOTS.size} slots" if series.size > SLOTS.size
    { field: field, type: "nominal", title: nil,
      scale: { domain: series, range: SLOTS.first(series.size) },
      legend: { orient: "top" } }
  end

  # band-keyed hash for the ordinal ramp, for callers that only have an
  # ordered band list (eg a "top N" cut). Falls back to the neutral past the
  # ramp's five steps rather than erroring - an ordinal ramp overflowing just
  # means "less distinct", not the CVD failure a categorical overflow risks.
  def ci_ordinal_colors(bands)
    bands.each_with_index.to_h { |band, i| [ band, ORDINAL[i] || "var(--ci-chart-cancelled)" ] }
  end

  # datum keys may arrive as strings or symbols from the caller; band_index is
  # derived here so the stack order has one source of truth (bands), not two
  def ci_stacked_bar_spec(values, x:, x_title:, y_title:, band_field:, bands:, colors:, temporal: true, sort: nil)
    rows = values.map do |row|
      band = row[band_field] || row[band_field.to_s] || row[band_field.to_sym]
      row.merge(band_index: bands.index(band) || bands.size)
    end
    ci_chart_base(rows).merge(
      # no cornerRadiusEnd here: vega-lite rounds it per mark, so on a stack it
      # would round every segment's top instead of just the stack's actual
      # top - reads as broken, not rounded. Grouped bars are single-segment,
      # their own top is the stack's top, so they keep the rounding.
      mark: { type: "bar", stroke: "var(--color-chart-bg)", strokeWidth: 2 },
      encoding: {
        x: ci_x_encoding(x, x_title, temporal: temporal, sort: sort),
        y: { field: "count", type: "quantitative", stack: "zero", title: y_title },
        color: { field: band_field, type: "nominal", title: nil,
                 scale: { domain: bands, range: bands.map { |band| colors.fetch(band) } },
                 legend: { orient: "top" } },
        order: { field: "band_index", type: "quantitative" },
        tooltip: [ { field: x, type: temporal ? "temporal" : "ordinal", title: x_title },
                   { field: band_field, type: "nominal" },
                   { field: "count", type: "quantitative" } ]
      }
    )
  end

  # one series gets no legend - the block heading names it. Two or more always do.
  def ci_line_spec(values, x:, x_title:, y_title:, series_field: nil, series: [], y_format: nil, rule: nil)
    encoding = {
      x: ci_x_encoding(x, x_title),
      y: { field: "value", type: "quantitative", title: y_title,
           axis: ({ format: y_format } if y_format).presence }.compact,
      tooltip: [ { field: x, type: "temporal", title: x_title },
                 { field: "value", type: "quantitative", title: y_title, format: ".3~s" } ]
    }
    if series_field
      encoding[:color] = ci_series_color(series_field, series)
      encoding[:tooltip] << { field: series_field, type: "nominal" }
    else
      encoding[:color] = { value: SLOTS.first }
    end

    layers = [ { mark: { type: "line", strokeWidth: 2, point: { size: 64, filled: true } },
                 encoding: encoding } ]
    if rule
      layers << { mark: { type: "rule", strokeWidth: 2, color: "var(--color-chart-dark-gray)" },
                  encoding: { y: { datum: rule[:value] } } }
      layers << { mark: { type: "text", align: "left", dx: 4, dy: -6,
                          color: "var(--color-chart-dark-gray)" },
                  encoding: { y: { datum: rule[:value] }, text: { value: rule[:label] } } }
    end
    ci_chart_base(values).merge(layer: layers)
  end

  def ci_grouped_bar_spec(values, x:, x_title:, y_title:, series_field:, series:, sort: nil)
    ci_chart_base(values).merge(
      mark: { type: "bar", cornerRadiusEnd: 4 },
      encoding: {
        x: { field: x, type: "nominal", title: x_title,
             sort: sort, axis: { labelAngle: 0 } }.compact,
        xOffset: { field: series_field },
        y: { field: "count", type: "quantitative", title: y_title },
        color: ci_series_color(series_field, series),
        tooltip: [ { field: x, type: "nominal", title: x_title },
                   { field: series_field, type: "nominal" },
                   { field: "count", type: "quantitative" } ]
      }
    )
  end

  # dense points need a nearest-point layer, or a reader has to hit an 8px dot
  def ci_scatter_spec(values, x:, x_title:, y:, y_title:)
    ci_chart_base(values).merge(
      mark: { type: "point", filled: true, size: 64, opacity: 0.6,
              stroke: "var(--color-chart-bg)", strokeWidth: 2 },
      encoding: {
        x: { field: x, type: "quantitative", title: x_title },
        y: { field: y, type: "quantitative", title: y_title },
        color: { value: SLOTS.first },
        tooltip: [ { field: x, type: "quantitative", title: x_title },
                   { field: y, type: "quantitative", title: y_title } ]
      }
    )
  end

  # small multiples: one column per era, shared y so the eras compare. no
  # outer width/height - the nested "spec" below carries fixed dimensions,
  # and vega-lite rejects width: "container" inside a facet
  def ci_faceted_line_spec(values, x:, x_title:, y_title:, facet_field:, series_field:, series:)
    ci_chart_base(values, width: nil, height: nil).merge(
      facet: { field: facet_field, type: "nominal", title: nil, columns: 3 },
      spec: { width: 240, height: 180,
              mark: { type: "line", strokeWidth: 2, point: { size: 64, filled: true } },
              encoding: {
                x: ci_x_encoding(x, x_title),
                y: { field: "value", type: "quantitative", title: y_title },
                color: ci_series_color(series_field, series),
                tooltip: [ { field: x, type: "temporal", title: x_title },
                           { field: series_field, type: "nominal" },
                           { field: "value", type: "quantitative" } ]
              } }
    )
  end
end
