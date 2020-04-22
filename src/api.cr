require "grip"

require "http/client"
require "uri"
require "json"

class Endpoints
  BASE_URL   = URI.parse "https://services8.arcgis.com/aCyQID5qQcyrJMm2/arcgis/rest/services/RHA_CurrentStats2_Public/FeatureServer/0/query"
  DATAPOINTS = [
    {"total_number_of_cases", "sum"},
    {"new_cases", "sum"},
    {"total_number_recovered", "sum"},
    {"currently_hospitalized", "sum"},
    {"current_in_icu", "sum"},
    {"total_number_of_deaths", "sum"},
    {"total_people_tested", "sum"},
    {"date_updated", "max"},
  ]

  struct Endpoint
    property uri : URI
    property field : String
    property stats_type : String

    def initialize(@uri, @field, @stats_type)
    end
  end

  class_getter lookup : Hash(String, Endpoint) = Hash(String, Endpoint).new

  def self.query_params(field, stats_type)
    params = HTTP::Params.build do |form|
      form.add "f", "json"
      form.add "where", "1=1"
      form.add "outFields", "*"
      form.add "returnGeometry", "false"
      form.add "outStatistics", [{
        "onStatisticField"      => field,
        "outStatisticFieldName" => "#{field}_#{stats_type}",
        "statisticType"         => stats_type,
      }].to_json
    end
  end

  def self.initialize
    DATAPOINTS.each do |datapoint|
      uri = BASE_URL.dup
      uri.query = self.query_params datapoint[0], datapoint[1]
      @@lookup[datapoint[0]] = Endpoint.new uri, datapoint[0], datapoint[1]
    end
  end
end

class Datapoint
  struct CachedData
    property last_updated : Time
    property data : NamedTuple(source: (NamedTuple(uri: String, body: JSON::Any)), value: JSON::Any)

    def initialize
      @last_updated = Time.utc - 15.seconds
      @data = {
        source: {
          uri:  "",
          body: JSON::Any.new nil,
        },
        value: JSON::Any.new nil,
      }
    end
  end

  class_getter cache : Hash(Endpoints::Endpoint, CachedData) = Hash(Endpoints::Endpoint, CachedData).new

  def self.initialize
    Endpoints.lookup.each do |field, endpoint|
      @@cache[endpoint] = CachedData.new
    end
  end

  def self.retrieve(endpoint)
    cache = @@cache[endpoint]

    now = Time.utc
    span = Time.utc - cache.last_updated

    if span.seconds > 10
      cache.last_updated = Time.utc

      arcgis_response = HTTP::Client.get endpoint.uri

      # TODO notice failure - response.status_code

      data = JSON.parse arcgis_response.body

      key = "#{endpoint.field}_#{endpoint.stats_type}"
      value = data["features"][0]["attributes"][key]

      fresh_data = {
        source: {
          uri:  endpoint.uri.to_s,
          body: data,
        },
        value: value,
      }

      cache.data = fresh_data

      @@cache[endpoint] = cache

      return fresh_data
    else
      return cache.data
    end
  end
end

class Datapoints < Grip::Controller::Http
  def get(context)
    url_params = url(context)

    json(context, {"message": "missing datapoint url param"}, 400) unless url_params.has_key? "datapoint"

    datapoint = url_params["datapoint"]
    endpoints = Endpoints.lookup

    if endpoints.has_key? datapoint
      endpoint = endpoints[datapoint]

      data = Datapoint.retrieve endpoint

      response = {} of String => (NamedTuple(uri: String, body: JSON::Any) | JSON::Any)
      query_params = query(context)

      response["source"] = data[:source] if query_params.has_key? "includeSource"
      response["value"] = data[:value]

      json(context, response)
    else
      json(context, {"message": "datapoint '#{datapoint}' not found"}, 404)
    end
  end
end

class ListDatapoints < Grip::Controller::Http
  def get(context)
    endpoints = Array(String).new
    Endpoints.lookup.each do |field, endpoint|
      endpoints << field
    end
    json(context, {datapoints: endpoints})
  end
end

class App < Grip::Application
  def initialize
    Endpoints.initialize
    Datapoint.initialize

    resource "/", ListDatapoints, only: [:get]
    resource "/datapoint/:datapoint", Datapoints, only: [:get]
  end
end

{Signal::INT, Signal::TERM}.each &.trap do
  puts "bye"
  exit
end

app = App.new

Grip.config.env = "production"

app.run
