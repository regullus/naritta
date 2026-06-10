import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const weatherZipKey = 'weather_zipcode';
const weatherCityKey = 'weather_city_name';

class WeatherData {
  final String city;
  final double tempF;
  final int weatherCode;
  final String icon;
  final DateTime fetchedAt;

  WeatherData({
    required this.city,
    required this.tempF,
    required this.weatherCode,
    required this.icon,
    required this.fetchedAt,
  });
}

String _weatherCodeToIcon(int code) {
  if (code == 0) return '☀️';
  if (code >= 1 && code <= 1) return '🌤️';
  if (code == 2) return '⛅';
  if (code == 3) return '☁️';
  if (code >= 45 && code <= 48) return '🌫️';
  if (code >= 51 && code <= 67) return '🌧️';
  if (code >= 71 && code <= 77) return '❄️';
  if (code >= 80 && code <= 82) return '🌧️';
  if (code >= 95 && code <= 99) return '🌩️';
  return '🌡️';
}

/// Geocode a US zip code via Open-Meteo's geocoding API.
/// Returns {lat, lon, city} or null on failure.
Future<Map<String, dynamic>?> geocodeZipcode(String zip) async {
  try {
    final resp = await http.get(
      Uri.parse(
        'https://geocoding-api.open-meteo.com/v1/search?name=$zip&count=1&language=en&format=json',
      ),
    );
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body);
    final results = data['results'] as List?;
    if (results == null || results.isEmpty) return null;
    final r = results[0];
    return {
      'lat': r['latitude'],
      'lon': r['longitude'],
      'city': r['name'] ?? zip,
    };
  } catch (_) {
    return null;
  }
}

class WeatherNotifier extends StateNotifier<WeatherData?> {
  WeatherNotifier() : super(null) {
    // Disabled during development — no external calls
  }

  /// Force a refresh (called after user changes location in settings).
  void refresh() => _fetch();

  Future<void> _fetch() async {
    // Weather disabled during development
    return;
  }
}

final weatherProvider = StateNotifierProvider<WeatherNotifier, WeatherData?>((
  ref,
) {
  return WeatherNotifier();
});
