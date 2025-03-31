require 'sinatra'
require 'json'
require 'net/http'
require 'uri'
require 'csv'
require 'fileutils'

class CarService < Sinatra::Base
  # Basic constants
  EARTH_RADIUS = 6371.0
  TOMTOM_API_KEY = 'dWbDR9lXANVX3XFYaJWrerRXXPAV9PDt'
  OPENWEATHER_API_KEY = '5bff22751b54cff1cf4dfe5c05b6c706'

  # Process management
  @@shutdown_requested = false
  @@start_time = Time.now

  # Store car info
  @@car_state = {
    "car_id" => "44135bc5-be28-44b2-ad6f-9b9d7f3d210e",
    "current_latitude" => 48.1351,
    "current_longitude" => 11.5820,
    "current_speed" => 60.0,
    "current_speed_limit" => 100,
    "fog_lights" => false,
    "lights" => false,
    "arrived" => false,
    "current_threshold" => 25,
    "waypoints" => ["Karlsplatz 1, 80335 Munich", "Neuhauser Str. 1, 80331 Munich"],
    "timestamp" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
    "instance_id" => nil,
    "last_update_time" => Time.now.to_f,
    "route_points" => [],
    "current_route_index" => 0
  }

  # Create data folder if needed
  FileUtils.mkdir_p('data') unless File.directory?('data')

  # Basic helper functions
  def calculate_distance(lat1, lon1, lat2, lon2)
    lat1, lon1, lat2, lon2 = [lat1, lon1, lat2, lon2].map { |x| x * Math::PI / 180 }
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = Math.sin(dlat/2)**2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dlon/2)**2
    c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
    EARTH_RADIUS * c
  end

  def calculate_bearing(lat1, lon1, lat2, lon2)
    dLon = (lon2 - lon1) * Math::PI / 180.0
    lat1_rad = lat1 * Math::PI / 180.0
    lat2_rad = lat2 * Math::PI / 180.0
    y = Math.sin(dLon) * Math.cos(lat2_rad)
    x = Math.cos(lat1_rad) * Math.sin(lat2_rad) - Math.sin(lat1_rad) * Math.cos(lat2_rad) * Math.cos(dLon)
    bearing = Math.atan2(y, x) * 180.0 / Math::PI
    (bearing + 360) % 360
  end

  def handle_instance_id(instance_id)
    return nil if instance_id.nil? || instance_id.empty? || instance_id == "null"
    
    # If it's a plain number, return it as is
    if instance_id.match?(/^\d+$/)
      return instance_id
    end
    
    # Decode URL-encoded string if needed
    if instance_id.include?('%')
      instance_id = URI.decode_www_form_component(instance_id)
    end
    
    # Handle CPEE URL format
    if instance_id.include?('cpee.org/flow/engine/')
      # Extract instance ID from URL
      instance_id = instance_id.split('/').last
      return instance_id
    end
    
    # Handle case where instance_id is passed as a literal string
    if instance_id == "#{ENV['CPEE_INSTANCE_ID']}" || instance_id == "#{ENV['CPEE_INSTANCE_ID']}"
      return ENV['CPEE_INSTANCE_ID']
    end
    
    # If instance_id is still a literal string after decoding, try to get the actual value
    if instance_id.start_with?('#{') && instance_id.end_with?('}')
      return ENV['CPEE_INSTANCE_ID']
    end
    
    # If instance_id is still a literal string after decoding, try to get the actual value
    if instance_id.include?('ENV') && instance_id.include?('CPEE_INSTANCE_ID')
      return ENV['CPEE_INSTANCE_ID']
    end
    
    # If instance_id is still a literal string after decoding, try to get the actual value
    if instance_id.include?('CPEE_INSTANCE_ID')
      return ENV['CPEE_INSTANCE_ID']
    end
    
    # If instance_id is still a literal string after decoding, try to get the actual value
    if instance_id.include?('ENV')
      return ENV['CPEE_INSTANCE_ID']
    end
    
    instance_id
  end

  # Basic routes
  get '/' do
    content_type :json
    { 
      status: "ok", 
      timestamp: Time.now.strftime("%Y-%m-%d %H:%M:%S"),
      uptime: Time.now - @@start_time,
      shutdown_requested: @@shutdown_requested
    }.to_json
  end

  get '/health' do
    content_type :json
    {
      status: "healthy",
      uptime: Time.now - @@start_time,
      car_state: @@car_state,
      shutdown_requested: @@shutdown_requested
    }.to_json
  end

  post '/shutdown' do
    content_type :json
    @@shutdown_requested = true
    {
      status: "shutting_down",
      message: "Server will shutdown after current requests complete"
    }.to_json
  end

  get '/get_car_state' do
    content_type :json
    instance_id = handle_instance_id(params["instance_id"])
    
    # Update car position
    current_time = Time.now.to_f
    time_elapsed = current_time - @@car_state["last_update_time"]
    
    if time_elapsed > 0 && @@car_state["current_speed"] > 0
      speed = @@car_state["current_speed"]
      distance = (speed * time_elapsed) / 3600.0  # km
      
      route_points = @@car_state["route_points"]
      current_index = @@car_state["current_route_index"]
      
      if route_points && route_points.length > 0
        if current_index >= route_points.length - 1
          @@car_state["arrived"] = true
          @@car_state["current_speed"] = 0.0
          @@car_state["current_latitude"] = route_points[-1][0]
          @@car_state["current_longitude"] = route_points[-1][1]
          puts "Car has arrived at destination"
        else
          current_point = route_points[current_index]
          next_point = route_points[current_index + 1]
          
          distance_to_next = calculate_distance(
            @@car_state["current_latitude"],
            @@car_state["current_longitude"],
            next_point[0],
            next_point[1]
          )
          
          if distance >= distance_to_next
            @@car_state["current_route_index"] += 1
            @@car_state["current_latitude"] = next_point[0]
            @@car_state["current_longitude"] = next_point[1]
            puts "Car reached waypoint #{current_index + 1} of #{route_points.length}"
          else
            progress = distance / distance_to_next
            @@car_state["current_latitude"] += (next_point[0] - current_point[0]) * progress
            @@car_state["current_longitude"] += (next_point[1] - current_point[1]) * progress
          end
        end
      end
      
      @@car_state["last_update_time"] = current_time
    end
    
    # Save car data
    save_process_data('car_state', { 'instance_id' => instance_id })
    
    response = {
      "car" => @@car_state,
      "timestamp" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
      "instance_id" => instance_id
    }
    
    response.to_json
  end

  post '/update_car_speed' do
    content_type :json
    begin
      # Try to parse as JSON first
      data = JSON.parse(request.body.read)
    rescue JSON::ParserError
      # If not JSON, use form data
      data = {
        "current_speed" => params["current_speed"],
        "current_threshold" => params["current_threshold"],
        "instance_id" => params["instance_id"]
      }
    end
    
    speed = data["current_speed"] || 60.0
    threshold = data["current_threshold"] || 25.0
    instance_id = handle_instance_id(data["instance_id"]) || @@car_state["instance_id"]
    
    @@car_state["current_speed"] = speed.to_f
    @@car_state["current_threshold"] = threshold.to_f
    @@car_state["instance_id"] = instance_id
    @@car_state["last_update_time"] = Time.now.to_f
    
    response = {
      "car" => @@car_state,
      "timestamp" => Time.now.strftime("%Y-%m-%d %H:%M:%S")
    }
    
    response.to_json
  end

  get '/get_route_data' do
    content_type :json
    begin
      waypoints = params["waypoints"]
      instance_id = handle_instance_id(params["instance_id"])

      # Set default instance ID if none provided
      unless instance_id
        instance_id = "default_#{Time.now.to_i}"
      end

      # Handle waypoints input
      if waypoints.is_a?(String)
        begin
          waypoints = JSON.parse(waypoints)
        rescue JSON::ParserError => e
          waypoints = ["Karlsplatz 1, 80335 Munich", "Neuhauser Str. 1, 80331 Munich"]
        end
      end

      # Get start and end coordinates
      start_coords = get_city_coordinates_for_city(waypoints[0])
      end_coords = get_city_coordinates_for_city(waypoints[1])

      if !start_coords || !end_coords
        raise "Could not find coordinates for waypoints"
      end

      # Get route points
      route_points = get_route_from_tomtom(
        start_coords[:lat],
        start_coords[:lon],
        end_coords[:lat],
        end_coords[:lon]
      )

      if route_points && route_points.length > 0
        # Update car state with route info
        @@car_state["route_points"] = route_points
        @@car_state["current_route_index"] = 0
        @@car_state["instance_id"] = instance_id
        @@car_state["route_initialized"] = true

        # Calculate total distance
        total_distance = 0
        for i in 0..route_points.length-2
          total_distance += calculate_distance(
            route_points[i][0],
            route_points[i][1],
            route_points[i+1][0],
            route_points[i+1][1]
          )
        end

        # Get traffic delay
        traffic_data = get_traffic_from_tomtom(start_coords[:lat], start_coords[:lon])
        traffic_delay = traffic_data ? (traffic_data["free_flow_speed"] - traffic_data["current_speed"]) * 60 : 300

        # Create route data
        route_data = {
          "distance" => total_distance.round(1),
          "duration" => (total_distance / @@car_state["current_speed"] * 3600).to_i,
          "traffic_delay" => traffic_delay,
          "route_points" => route_points,
          "timestamps" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
          "instance_id" => instance_id
        }

        @@car_state["route_data"] = route_data
        @@car_state["route_data_retrieved"] = true
        @@car_state["main_loop_started"] = true

        save_process_data('route', route_data)
        return route_data.to_json
      else
        # Use simple fallback route if no route points
        route_points = generate_fallback_route(
          start_coords[:lat],
          start_coords[:lon],
          end_coords[:lat],
          end_coords[:lon]
        )
        
        @@car_state["route_points"] = route_points
        @@car_state["current_route_index"] = 0
        @@car_state["instance_id"] = instance_id
        @@car_state["route_initialized"] = true

        # Calculate total distance for fallback route
        total_distance = 0
        for i in 0..route_points.length-2
          total_distance += calculate_distance(
            route_points[i][0],
            route_points[i][1],
            route_points[i+1][0],
            route_points[i+1][1]
          )
        end

        route_data = {
          "distance" => total_distance.round(1),
          "duration" => (total_distance / @@car_state["current_speed"] * 3600).to_i,
          "traffic_delay" => 300,
          "route_points" => route_points,
          "timestamps" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
          "instance_id" => instance_id
        }

        @@car_state["route_data"] = route_data
        @@car_state["route_data_retrieved"] = true
        @@car_state["main_loop_started"] = true

        save_process_data('route', route_data)
        return route_data.to_json
      end
    rescue => e
      status 500
      {
        "error" => e.message,
        "instance_id" => params["instance_id"] || "unknown",
        "timestamps" => Time.now.strftime("%Y-%m-%d %H:%M:%S")
      }.to_json
    end
  end

  get '/get_traffic_data' do
    content_type :json
    latitude = params["latitude"]
    longitude = params["longitude"]
    instance_id = handle_instance_id(params["instance_id"])
    
    # Get traffic data
    traffic_data = get_traffic_from_tomtom(latitude.to_f, longitude.to_f)
    
    if traffic_data
      response = {
        "incidents" => traffic_data["incidents"],
        "live_speeds" => traffic_data["current_speed"],
        "free_flow_speeds" => traffic_data["free_flow_speed"],
        "road_closure" => traffic_data["road_closure"],
        "confidence" => traffic_data["confidence"],
        "is_rush_hour" => traffic_data["is_rush_hour"],
        "timestamps" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
        "instance_id" => instance_id
      }
      
      # Save traffic data
      save_process_data('traffic', traffic_data)
    else
      # Use simulated data if no real data
      response = generate_simulated_traffic_data.merge({
        "timestamps" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
        "instance_id" => instance_id
      })
      
      save_process_data('traffic', response)
    end
    
    @@car_state["last_traffic_update"] = Time.now.to_f
    response.to_json
  end

  get '/get_weather_data' do
    content_type :json
    latitude = params["latitude"]
    longitude = params["longitude"]
    instance_id = handle_instance_id(params["instance_id"])
    
    # Get weather data
    weather_data = get_weather_from_openweather(latitude.to_f, longitude.to_f)
    
    if weather_data
      response = {
        "location" => "Munich",
        "temperatures" => weather_data["temperature"],
        "weather_conditions" => weather_data["conditions"],
        "last_updated" => Time.now.strftime("%Y-%m-%d %H:%M"),
        "visibility" => weather_data["visibility"],
        "weather_threshold" => weather_data["weather_threshold"],
        "timestamps" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
        "instance_id" => instance_id
      }
      
      # Save weather data
      save_process_data('weather', weather_data)
    else
      # Use simulated data if no real data
      response = generate_simulated_weather_data.merge({
        "timestamps" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
        "instance_id" => instance_id
      })
      
      save_process_data('weather', response)
    end
    
    @@car_state["last_weather_update"] = Time.now.to_f
    response.to_json
  end

  def calculate_new_position(current_lat, current_lon, speed, time_elapsed)
    # Get current route points
    route_points = @@car_state["route_points"]
    current_index = @@car_state["current_route_index"]
    
    # If no route points, use simple calculation
    if !route_points || route_points.length == 0
      puts "No route points. Using simple calculation."
      return calculate_straight_line_position(current_lat, current_lon, speed, time_elapsed)
    end
    
    # If we reached the end, stay there
    if current_index >= route_points.length - 1
      puts "Reached final destination."
      @@car_state["arrived"] = true
      return route_points[-1]
    end
    
    # Get current and next points
    current_point = route_points[current_index]
    next_point = route_points[current_index + 1]
    
    # Calculate distance to next point
    distance_to_next = calculate_distance(
      current_lat, current_lon,
      next_point[0], next_point[1]
    )
    
    # Calculate how far we moved
    distance_traveled = (speed * time_elapsed) / 3600.0  # km
    
    # If we reached next point
    if distance_traveled >= distance_to_next
      @@car_state["current_route_index"] += 1
      puts "Reached point #{current_index + 1} of #{route_points.length}"
      return next_point
    end
    
    # Calculate how far along we are
    progress = distance_traveled / distance_to_next
    
    # Move towards next point
    new_lat = current_lat + (next_point[0] - current_lat) * progress
    new_lon = current_lon + (next_point[1] - current_lon) * progress
    
    [new_lat, new_lon]
  end

  def calculate_straight_line_position(current_lat, current_lon, speed, time_elapsed)
    # Get destination coordinates
    route_points = @@car_state["route_points"]
    if route_points && route_points.length > 0
      dest_lat = route_points[-1][0]
      dest_lon = route_points[-1][1]
    else
      # Use default coordinates if no route
      dest_lat = 48.1374
      dest_lon = 11.5737
    end
    
    # Calculate total distance
    total_distance = calculate_distance(current_lat, current_lon, dest_lat, dest_lon)
    
    # Calculate how far we moved
    distance_traveled = (speed * time_elapsed) / 3600.0  # km
    
    # If we reached destination
    if distance_traveled >= total_distance
      @@car_state["arrived"] = true
      return [dest_lat, dest_lon]
    end
    
    # Calculate how far along we are
    progress = distance_traveled / total_distance
    
    # Move towards destination
    new_lat = current_lat + (dest_lat - current_lat) * progress
    new_lon = current_lon + (dest_lon - current_lon) * progress
    
    [new_lat, new_lon]
  end

  def check_arrival(current_lat, current_lon, dest_lat, dest_lon)
    # Get destination coordinates
    route_points = @@car_state["route_points"]
    if route_points && route_points.length > 0
      dest_lat = route_points[-1][0]
      dest_lon = route_points[-1][1]
    end
    
    # Calculate distance to destination
    distance = calculate_distance(current_lat, current_lon, dest_lat, dest_lon)
    
    # Calculate direction to destination
    dLon = (dest_lon - current_lon) * Math::PI / 180
    y = Math.sin(dLon) * Math.cos(dest_lat * Math::PI / 180)
    x = Math.cos(current_lat * Math::PI / 180) * Math.sin(dest_lat * Math::PI / 180) -
        Math.sin(current_lat * Math::PI / 180) * Math.cos(dest_lat * Math::PI / 180) * Math.cos(dLon)
    bearing = Math.atan2(y, x) * 180 / Math::PI
    bearing = (bearing + 360) % 360
    
    # Check if we're close enough and moving in right direction
    arrived = distance < 0.1 && bearing.between?(0, 180)
    
    puts "Arrival check - Distance: #{distance} km, Direction: #{bearing}°, Arrived: #{arrived}"
    arrived
  end

  def calculate_speed_threshold(traffic_data, weather_data)
    threshold = 0
    
    # Add threshold based on traffic confidence
    if traffic_data && traffic_data["confidence"] == 1
      threshold += 2
    else
      threshold += 1
    end
    
    # Add threshold based on speed difference
    if traffic_data && traffic_data["free_flow_speed"] > traffic_data["current_speed"]
      free_flow = traffic_data["free_flow_speed"].to_f
      live_speed = traffic_data["current_speed"].to_f
      slowdown = ((free_flow - live_speed) / free_flow) * 100
      
      if slowdown <= 10
        threshold += 2
      elsif slowdown <= 30
        threshold += 5
      elsif slowdown <= 50
        threshold += 8
      else
        threshold += 10
      end
    end
    
    # Add rush hour threshold
    if traffic_data && traffic_data["is_rush_hour"]
      threshold += 2
    end
    
    # Add traffic incidents threshold
    if traffic_data && traffic_data["incidents"] > 0
      incidents = traffic_data["incidents"]
      threshold += [incidents * 2, 8].min
    end
    
    # Add road closure threshold
    if traffic_data && traffic_data["road_closure"]
      threshold += 8
    end
    
    # Add weather threshold
    if weather_data && weather_data["weather_threshold"]
      threshold += weather_data["weather_threshold"]
    end
    
    threshold
  end

  def get_traffic_from_tomtom(lat, lon)
    begin
      # Check if API key is valid
      if !TOMTOM_API_KEY || TOMTOM_API_KEY.empty? || TOMTOM_API_KEY == 'YOUR_API_KEY'
        puts "No valid API key. Using simulated traffic data."
        return generate_simulated_traffic_data
      end

      # Make API request
      uri = URI("https://api.tomtom.com/traffic/services/4/flowSegmentData/relative/10/json")
      params = {
        key: TOMTOM_API_KEY,
        point: "#{lat},#{lon}",
        unit: "KMPH"
      }
      uri.query = URI.encode_www_form(params)

      response = Net::HTTP.get_response(uri)
      
      if response.code.to_i >= 400
        puts "API error: #{response.body}. Using simulated data."
        return generate_simulated_traffic_data
      end

      data = JSON.parse(response.body)

      if data["flowSegmentData"]
        segment = data["flowSegmentData"]
        current_hour = Time.now.hour
        is_rush_hour = current_hour.between?(6, 9) || current_hour.between?(16, 19)
        
        return {
          "current_speed" => segment["currentSpeed"],
          "free_flow_speed" => segment["freeFlowSpeed"],
          "confidence" => segment["confidence"],
          "is_rush_hour" => is_rush_hour,
          "incidents" => segment["incidents"] || 0,
          "road_closure" => segment["roadClosure"] || false
        }
      end
    rescue => e
      puts "Error getting traffic data: #{e.message}. Using simulated data."
    end
    generate_simulated_traffic_data
  end

  def generate_simulated_traffic_data
    current_hour = Time.now.hour
    is_rush_hour = current_hour.between?(6, 9) || current_hour.between?(16, 19)
    
    {
      "current_speed" => is_rush_hour ? 40 : 60,
      "free_flow_speed" => 70,
      "confidence" => 0.8,
      "is_rush_hour" => is_rush_hour,
      "incidents" => 0,
      "road_closure" => false
    }
  end

  def get_weather_from_openweather(lat, lon)
    begin
      # Check if API key is valid
      if !OPENWEATHER_API_KEY || OPENWEATHER_API_KEY.empty?
        puts "No valid API key. Using simulated weather data."
        return generate_simulated_weather_data
      end

      # Make API request
      uri = URI("https://api.openweathermap.org/data/2.5/weather")
      params = {
        lat: lat,
        lon: lon,
        appid: OPENWEATHER_API_KEY,
        units: 'metric'
      }
      uri.query = URI.encode_www_form(params)

      response = Net::HTTP.get_response(uri)
      
      if response.code.to_i >= 400
        puts "API error: #{response.body}. Using simulated data."
        return generate_simulated_weather_data
      end

      data = JSON.parse(response.body)

      if data
        visibility = data["visibility"] ? data["visibility"] / 1000.0 : 10.0
        conditions = data["weather"][0]["description"]
        temperature = data["main"]["temp"]
        
        weather_threshold = calculate_weather_threshold(visibility)
        
        return {
          "temperature" => temperature,
          "conditions" => conditions,
          "visibility" => visibility,
          "weather_threshold" => weather_threshold
        }
      end
    rescue => e
      puts "Error getting weather data: #{e.message}. Using simulated data."
    end
    generate_simulated_weather_data
  end

  def generate_simulated_weather_data
    {
      "temperature" => 20.0,
      "conditions" => "Clear",
      "visibility" => 10.0,
      "weather_threshold" => 0
    }
  end

  def calculate_weather_threshold(visibility)
    threshold = 0
    case visibility
    when 0.1..0.5 then threshold += 8
    when 0.5..1   then threshold += 5
    when 1..2     then threshold += 3
    when 2..5     then threshold += 2
    end
    threshold
  end

  def get_route_from_tomtom(start_lat, start_lon, end_lat, end_lon)
    begin
      # Check if API key is valid
      if !TOMTOM_API_KEY || TOMTOM_API_KEY.empty? || TOMTOM_API_KEY == 'YOUR_API_KEY'
        puts "No valid API key. Using fallback route."
        return generate_fallback_route(start_lat, start_lon, end_lat, end_lon)
      end

      # Make API request
      uri = URI("https://api.tomtom.com/routing/1/calculateRoute/#{start_lat},#{start_lon}:#{end_lat},#{end_lon}/json")
      params = {
        key: TOMTOM_API_KEY
      }
      uri.query = URI.encode_www_form(params)

      response = Net::HTTP.get_response(uri)
      
      if response.code.to_i >= 400
        puts "API error: #{response.body}. Using fallback route."
        return generate_fallback_route(start_lat, start_lon, end_lat, end_lon)
      end

      data = JSON.parse(response.body)

      if data["routes"] && data["routes"][0]["legs"]
        # Extract route points from the response
        route_points = []
        data["routes"][0]["legs"][0]["points"].each do |point|
          route_points << [point["latitude"], point["longitude"]]
        end
        return route_points
      end
    rescue => e
      puts "Error getting route data: #{e.message}. Using fallback route."
    end
    generate_fallback_route(start_lat, start_lon, end_lat, end_lon)
  end

  def generate_fallback_route(start_lat, start_lon, end_lat, end_lon)
    # Generate a simple route with 5 points between start and end
    route_points = []
    
    # Add start point
    route_points << [start_lat, start_lon]
    
    # Calculate intermediate points
    for i in 1..3
      progress = i / 4.0
      lat = start_lat + (end_lat - start_lat) * progress
      lon = start_lon + (end_lon - start_lon) * progress
      # Add some random variation to make it look more realistic
      lat += (rand - 0.5) * 0.001
      lon += (rand - 0.5) * 0.001
      route_points << [lat, lon]
    end
    
    # Add end point
    route_points << [end_lat, end_lon]
    
    route_points
  end

  post '/update_instance_id' do
    content_type :json
    begin
      # Try to parse as JSON first
      data = JSON.parse(request.body.read)
    rescue JSON::ParserError
      # If not JSON, use form data
      data = {
        "instance_id" => params["instance_id"],
        "waypoints" => params["waypoints"]
      }
    end
    
    instance_id = handle_instance_id(data["instance_id"])
    waypoints = data["waypoints"]
    
    @@car_state["instance_id"] = instance_id
    @@car_state["waypoints"] = waypoints.split(',') if waypoints
    
    response = {
      "car" => @@car_state,
      "timestamp" => Time.now.strftime("%Y-%m-%d %H:%M:%S")
    }
    
    response.to_json
  end

  def save_process_data(data_type, data)
    timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
    instance_id = data['instance_id'] || @@car_state['instance_id'] || 'unknown'
    
    # Create folder for this instance
    instance_dir = File.join('data', instance_id)
    FileUtils.mkdir_p(instance_dir) unless File.directory?(instance_dir)
    
    case data_type
    when 'car_state'
      CSV.open(File.join(instance_dir, 'car_state.csv'), 'a') do |csv|
        # Add header if file is new
        if !File.size?(File.join(instance_dir, 'car_state.csv'))
          csv << ['timestamp', 'latitude', 'longitude', 'speed', 'speed_limit', 'threshold', 
                 'lights', 'fog_lights', 'arrived', 'route_index', 'distance_to_destination']
        end
        
        # Add car state data
        distance_to_destination = 0
        if @@car_state['route_points'] && @@car_state['route_points'].length > 0
          distance_to_destination = calculate_distance(
            @@car_state['current_latitude'],
            @@car_state['current_longitude'],
            @@car_state['route_points'].last[0],
            @@car_state['route_points'].last[1]
          )
        end
        
        csv << [
          timestamp,
          @@car_state['current_latitude'],
          @@car_state['current_longitude'],
          @@car_state['current_speed'],
          @@car_state['current_speed_limit'],
          @@car_state['current_threshold'],
          @@car_state['lights'],
          @@car_state['fog_lights'],
          @@car_state['arrived'],
          @@car_state['current_route_index'],
          distance_to_destination
        ]
      end
      
    when 'traffic'
      CSV.open(File.join(instance_dir, 'traffic_data.csv'), 'a') do |csv|
        # Add header if file is new
        if !File.size?(File.join(instance_dir, 'traffic_data.csv'))
          csv << ['timestamp', 'latitude', 'longitude', 'current_speed', 'free_flow_speed', 
                 'confidence', 'is_rush_hour', 'incidents', 'road_closure']
        end
        
        # Add traffic data
        csv << [
          timestamp,
          @@car_state['current_latitude'],
          @@car_state['current_longitude'],
          data['current_speed'],
          data['free_flow_speed'],
          data['confidence'],
          data['is_rush_hour'],
          data['incidents'],
          data['road_closure']
        ]
      end
      
    when 'weather'
      CSV.open(File.join(instance_dir, 'weather_data.csv'), 'a') do |csv|
        # Add header if file is new
        if !File.size?(File.join(instance_dir, 'weather_data.csv'))
          csv << ['timestamp', 'latitude', 'longitude', 'temperature', 'conditions', 
                 'visibility', 'weather_threshold']
        end
        
        # Add weather data
        csv << [
          timestamp,
          @@car_state['current_latitude'],
          @@car_state['current_longitude'],
          data['temperature'],
          data['conditions'],
          data['visibility'],
          data['weather_threshold']
        ]
      end
      
    when 'route'
      CSV.open(File.join(instance_dir, 'route_data.csv'), 'a') do |csv|
        # Add header if file is new
        if !File.size?(File.join(instance_dir, 'route_data.csv'))
          csv << ['timestamp', 'total_distance', 'duration', 'traffic_delay', 
                 'route_points_count', 'current_route_index']
        end
        
        # Add route data
        csv << [
          timestamp,
          data['distance'],
          data['duration'],
          data['traffic_delay'],
          data['route_points'].length,
          @@car_state['current_route_index']
        ]
      end
    end
  end

  get '/get_statistics' do
    content_type :json
    instance_id = params["instance_id"] || 'unknown'
    instance_dir = File.join('data', instance_id)
    
    # Get all instance folders
    instances = Dir.glob(File.join('data', '*')).select { |f| File.directory?(f) }
    
    # Get data for each instance
    instances_data = []
    for inst_dir in instances
      inst_id = File.basename(inst_dir)
      traffic_data = []
      weather_data = []
      
      # Read traffic data
      if File.exist?(File.join(inst_dir, 'traffic_data.csv'))
        traffic_data = CSV.read(File.join(inst_dir, 'traffic_data.csv'), headers: true).map(&:to_h)
      end
      
      # Read weather data
      if File.exist?(File.join(inst_dir, 'weather_data.csv'))
        weather_data = CSV.read(File.join(inst_dir, 'weather_data.csv'), headers: true).map(&:to_h)
      end
      
      # Calculate summary
      total_records = traffic_data.length
      avg_speed = 0
      avg_temp = 0
      total_incidents = 0
      
      if !traffic_data.empty?
        speeds = traffic_data.map { |d| d['live_speed'].to_f }
        avg_speed = speeds.sum / speeds.length
        total_incidents = traffic_data.map { |d| d['incidents'].to_i }.sum
      end
      
      if !weather_data.empty?
        temps = weather_data.map { |d| d['temperature'].to_f }
        avg_temp = temps.sum / temps.length
      end
      
      instances_data << {
        'instance_id' => inst_id,
        'traffic_data' => traffic_data,
        'weather_data' => weather_data,
        'summary' => {
          'total_records' => total_records,
          'avg_speed' => avg_speed,
          'avg_temperature' => avg_temp,
          'total_incidents' => total_incidents
        }
      }
    end
    
    {
      'instances' => instances_data
    }.to_json
  end

  get '/get_city_coordinates' do
    content_type :json
    city = params["city"]
    instance_id = params["instance_id"]
    
    # For Munich addresses, return fixed coordinates
    if city.include?("Karlsplatz")
      response = {
        "latitude" => 48.1405,
        "longitude" => 11.56635,
        "arrival_latitude" => 48.1405,
        "arrival_longitude" => 11.56635,
        "instance_id" => instance_id
      }
    elsif city.include?("Neuhauser")
      response = {
        "latitude" => 48.1374,
        "longitude" => 11.5737,
        "arrival_latitude" => 48.1374,
        "arrival_longitude" => 11.5737,
        "instance_id" => instance_id
      }
    else
      # Default to Munich center coordinates
      response = {
        "latitude" => 48.1351,
        "longitude" => 11.5820,
        "arrival_latitude" => 48.1351,
        "arrival_longitude" => 11.5820,
        "instance_id" => instance_id
      }
    end
    
    response.to_json
  end

  def get_city_coordinates_for_city(city)
    # For Munich addresses, return fixed coordinates
    if city.include?("Karlsplatz")
      { lat: 48.1405, lon: 11.56635 }
    elsif city.include?("Neuhauser")
      { lat: 48.1374, lon: 11.5737 }
    else
      # Default to Munich center coordinates
      { lat: 48.1351, lon: 11.5820 }
    end
  end
end

# Start the app
if __FILE__ == $0
  begin
    puts "Starting Car Service on port 15000..."
    puts "Process ID: #{Process.pid}"
    puts "Press Ctrl+C to stop the server"
    
    # Set up signal handlers
    Signal.trap("INT") do
      puts "\nReceived shutdown signal. Cleaning up..."
      @@shutdown_requested = true
    end
    
    Signal.trap("TERM") do
      puts "\nReceived termination signal. Cleaning up..."
      @@shutdown_requested = true
    end
    
    # Start the server
    CarService.run! host: '0.0.0.0', port: 15000
  rescue => e
    puts "Error starting Car Service: #{e.message}"
    puts e.backtrace
    exit 1
  end
end 