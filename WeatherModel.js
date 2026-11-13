// The weather tile's state that does not need Quickshell: where to report for,
// in which unit, and how Open-Meteo's answer reads (conditions, glyphs, days).

// A place as { name, latitude, longitude, country }: the latitude and the
// longitude are numbers, or null when unknown. Takes qDock's weatherLocation
// setting or Omarchy's weather.json, which share this shape (the country
// comes from the geocoder, when the place was picked in qDock's settings).
function parsePlace(value) {
  var data = value
  if (typeof value === "string") {
    try { data = JSON.parse(value) } catch (e) { data = null }
  }
  if (!data || typeof data !== "object") return { name: "", latitude: null, longitude: null, country: "" }
  var latitude = parseFloat(data.latitude)
  var longitude = parseFloat(data.longitude)
  var known = !isNaN(latitude) && !isNaN(longitude) && Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180
  return {
    name: typeof data.name === "string" ? data.name.trim() : "",
    latitude: known ? latitude : null,
    longitude: known ? longitude : null,
    country: typeof data.country === "string" ? data.country.trim() : (typeof data.country_code === "string" ? data.country_code.trim() : "")
  }
}

function isSet(place) {
  return !!place && (place.name !== "" || place.latitude !== null)
}

function hasCoordinates(place) {
  return !!place && place.latitude !== null && place.longitude !== null
}

// qDock's own place, else Omarchy's (the bar's weather panel), else none: the
// tile then leads to its settings rather than guess where this machine is.
function effectivePlace(own, omarchy) {
  if (isSet(own)) return own
  if (isSet(omarchy)) return omarchy
  return parsePlace(null)
}

// Open-Meteo's geocoder → up to five places, with their region for the list.
function parseGeocoding(raw) {
  var data
  try { data = JSON.parse(String(raw || "{}")) } catch (e) { return [] }
  var results = data && Array.isArray(data.results) ? data.results : []
  var out = []
  for (var i = 0; i < results.length && out.length < 5; i++) {
    var r = results[i]
    if (!r || !r.name || r.latitude === undefined || r.longitude === undefined) continue
    out.push({
      name: String(r.name),
      region: [r.admin1, r.country].filter(function(part) { return !!part }).join(", "),
      latitude: Number(r.latitude),
      longitude: Number(r.longitude),
      country: String(r.country_code || "")
    })
  }
  return out
}

function forecastUrl(place) {
  return "https://api.open-meteo.com/v1/forecast"
    + "?latitude=" + encodeURIComponent(String(place.latitude))
    + "&longitude=" + encodeURIComponent(String(place.longitude))
    + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
    + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
    + "&forecast_days=4&timezone=auto"
}

function geocodingUrl(name, language) {
  return "https://geocoding-api.open-meteo.com/v1/search?count=5&format=json"
    + "&language=" + encodeURIComponent(String(language || "en").slice(0, 2))
    + "&name=" + encodeURIComponent(String(name || ""))
}

// A forecast page for the place, when Omarchy's weather panel is not in the bar.
function detailsUrl(place) {
  if (!hasCoordinates(place)) return "https://www.yr.no/en"
  return "https://www.yr.no/en/forecast/daily-table/" + place.latitude.toFixed(4) + "," + place.longitude.toFixed(4)
}

// Fahrenheit for the United States, Liberia and Myanmar, by the place's
// country, else by the locale. unit: "metric", "imperial", or anything else
// for automatic (inherit, the unit of Omarchy's weather panel, comes first).
function usesImperial(unit, inherit, country, localeName) {
  var u = String(unit || "").toLowerCase()
  if (u === "imperial" || u === "metric") return u === "imperial"
  var i = String(inherit || "").toLowerCase()
  if (i === "imperial" || i === "metric") return i === "imperial"
  var c = String(country || "").trim().toLowerCase()
  if (c) return ["us", "usa", "lr", "mm", "united states", "liberia", "myanmar"].indexOf(c) >= 0
  var name = String(localeName || "").replace(".", "_")
  return /^en[_-](US|LR)($|[_.-])/.test(name) || /^my($|[_.-])/.test(name)
}

function round(value) {
  var n = Number(value)
  return value === null || value === undefined || value === "" || isNaN(n) ? null : Math.round(n)
}

// Open-Meteo's answer (always metric) → { now, days }, in the unit asked;
// null when it holds no current temperature.
function parseForecast(raw, imperial, today) {
  var data
  try { data = typeof raw === "string" ? JSON.parse(raw) : raw } catch (e) { return null }
  var c = data && data.current
  if (!c || c.temperature_2m === undefined || c.temperature_2m === null) return null
  function temp(v) { return round(imperial && v !== null && v !== undefined ? v * 9 / 5 + 32 : v) }
  var now = {
    temp: temp(c.temperature_2m),
    feels: temp(c.apparent_temperature),
    humidity: round(c.relative_humidity_2m),
    wind: round(imperial ? c.wind_speed_10m * 0.621371 : c.wind_speed_10m),
    code: Number(c.weather_code) || 0,
    night: Number(c.is_day) === 0
  }
  var days = []
  var d = data.daily || {}
  var times = Array.isArray(d.time) ? d.time : []
  for (var i = 0; i < times.length && days.length < 3; i++) {
    if (today && String(times[i]).slice(0, 10) <= today) continue
    days.push({
      date: String(times[i]),
      max: temp(d.temperature_2m_max ? d.temperature_2m_max[i] : null),
      min: temp(d.temperature_2m_min ? d.temperature_2m_min[i] : null),
      code: d.weather_code ? Number(d.weather_code[i]) || 0 : 0
    })
  }
  return { now: now, days: days }
}

// WMO weather codes → the condition's i18n key (weather.<key>).
function conditionKey(code) {
  var c = Number(code) || 0
  if (c === 0) return "clear"
  if (c === 1) return "mainlyClear"
  if (c === 2) return "partlyCloudy"
  if (c === 3) return "overcast"
  if (c === 45 || c === 48) return "fog"
  if (c >= 51 && c <= 55) return "drizzle"
  if (c === 56 || c === 57 || c === 66 || c === 67) return "freezingRain"
  if (c >= 61 && c <= 65) return "rain"
  if (c >= 71 && c <= 77) return "snow"
  if (c >= 80 && c <= 82) return "showers"
  if (c === 85 || c === 86) return "snowShowers"
  if (c >= 95) return "thunderstorm"
  return "overcast"
}

// The Nerd Font weather glyphs of Omarchy's own panel, by WMO code.
function glyph(code, night) {
  switch (conditionKey(code)) {
    case "clear": return night ? "\u{e32b}" : "\u{e30d}"
    case "mainlyClear":
    case "partlyCloudy": return night ? "\u{e32e}" : "\u{e302}"
    case "fog": return night ? "\u{e346}" : "\u{e313}"
    case "drizzle": return night ? "\u{e333}" : "\u{e308}"
    case "rain":
    case "showers": return "\u{e318}"
    case "freezingRain": return "\u{e3ad}"
    case "snow":
    case "snowShowers": return "\u{e31a}"
    case "thunderstorm": return "\u{e31d}"
    default: return "\u{e33d}"
  }
}

// Whether the bar shows Omarchy's weather widget, and the unit set on it:
// the user's bar layout, else the default one. Entries are ids or objects.
function barWeather(userConfig, defaultConfig) {
  function layoutOf(config) {
    return config && config.bar && config.bar.layout && typeof config.bar.layout === "object" ? config.bar.layout : null
  }
  var layout = layoutOf(userConfig) || layoutOf(defaultConfig)
  if (!layout) return { shown: false, unit: "" }
  for (var section in layout) {
    var list = Array.isArray(layout[section]) ? layout[section] : []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      var id = entry && typeof entry === "object" ? entry.id : entry
      if (id === "omarchy.weather")
        return { shown: true, unit: entry && typeof entry.unit === "string" ? entry.unit : "" }
    }
  }
  return { shown: false, unit: "" }
}

if (typeof module !== "undefined") {
  module.exports = {
    parsePlace: parsePlace,
    isSet: isSet,
    hasCoordinates: hasCoordinates,
    effectivePlace: effectivePlace,
    parseGeocoding: parseGeocoding,
    forecastUrl: forecastUrl,
    geocodingUrl: geocodingUrl,
    detailsUrl: detailsUrl,
    usesImperial: usesImperial,
    parseForecast: parseForecast,
    conditionKey: conditionKey,
    glyph: glyph,
    barWeather: barWeather
  }
}
