require "bundler/setup"
Bundler.require(:default)
require "minitest/autorun"
require "minitest/pride"
require "logger"
require "active_record"
require "ostruct"

require "byebug"

ENV["TZ"] = "UTC"

adapter = ENV["ADAPTER"]
abort "No adapter specified" unless adapter

puts "Using #{adapter}"
require_relative "adapters/#{adapter}"

require_relative "support/activerecord" unless adapter == "enumerable"

# i18n
I18n.enforce_available_locales = true
I18n.backend.store_translations :de, date: {
  abbr_month_names: %w(Jan Feb Mar Apr Mai Jun Jul Aug Sep Okt Nov Dez).unshift(nil)
},
time: {
  formats: {special: "%b %e, %Y"}
}

class Minitest::Test

  TZ_US_CANADA = "Pacific Time (US & Canada)"
  TZ_TRANSFORM = "Asia/Manila"

  def setup
    if enumerable?
      @users = []
    else
      User.delete_all
    end
  end

  def sqlite?
    ENV["ADAPTER"] == "sqlite"
  end

  def enumerable?
    ENV["ADAPTER"] == "enumerable"
  end

  def postgresql?
    ENV["ADAPTER"] == "postgresql"
  end

  def mysql?
    ENV["ADAPTER"] == "mysql"
  end

  def redshift?
    ENV["ADAPTER"] == "redshift"
  end

  def create_user(created_at, score = 1)
    created_at = created_at.utc.to_s if created_at.is_a?(Time)

    if enumerable?
      user =
        OpenStruct.new(
          name: "Andrew",
          score: score,
          created_at: created_at ? utc.parse(created_at) : nil,
          created_on: created_at ? Date.parse(created_at) : nil
        )
      @users << user
    else
      user =
        User.new(
          name: "Andrew",
          score: score,
          created_at: created_at ? utc.parse(created_at) : nil,
          created_on: created_at ? Date.parse(created_at) : nil
        )

      if postgresql?
        user.deleted_at = user.created_at
      end

      user.save!

      # hack for Redshift adapter, which doesn't return id on creation...
      user = User.last if user.id.nil?

      user.update_columns(created_at: nil, created_on: nil) if created_at.nil?
    end

    user
  end

  def call_method(method, field, options)
    if enumerable?
      @users.group_by_period(method, **options) { |u| u.send(field) }.to_h { |k, v| [k, v.size] }
    elsif sqlite? && (method == :quarter || (options[:time_zone] && options[:time_zone] != "bad") || options[:day_start] || (Time.zone && options[:time_zone] != false))
      error = assert_raises(Groupdate::Error) { User.group_by_period(method, field, **options).count }
      assert_includes error.message, "not supported for SQLite"
      skip
    else
      User.group_by_period(method, field, **options).count
    end
  end

  def assert_result_time(method, expected_str, time_str, **options)
    tz = options[:time_zone] ? TZ_US_CANADA : utc
    expected_time = expected_str.is_a?(Time) ? expected_str : utc.parse(expected_str).in_time_zone(tz)
    expected = {expected_time => 1}
    assert_equal expected, result(method, time_str, :created_at, options)

    if postgresql?
      # test timestamptz
      assert_equal expected, result(method, time_str, :deleted_at, options)
    end
  end

  def assert_result_date(method, expected_date, time_str, options = {})
    create_user time_str
    expected = {Date.parse(expected_date) => 1}
    assert_equal expected, call_method(method, :created_at, options)

    expected_time = pt(options[:time_zone] || 'UTC').parse(expected_date)
    if options[:day_start]
      expected_time = expected_time.change(hour: options[:day_start], min: (options[:day_start] % 1) * 60)
    end
    expected = {expected_time => 1}

    # assert_equal expected, call_method(method, :created_on, options.merge(time_zone: time_zone ? TZ_US_CANADA : nil))
  end

  def assert_result(method, expected, time_str, options = {})
    assert_equal 1, result(method, time_str, :created_at, options)[expected]
  end

  def result(method, time_str, attribute = :created_at, options = {})
    create_user time_str unless attribute == :deleted_at
    call_method(method, attribute, options)
  end

  def utc
    ActiveSupport::TimeZone["UTC"]
  end

  def pt(tz = TZ_US_CANADA)
    ActiveSupport::TimeZone[tz]
  end
end
