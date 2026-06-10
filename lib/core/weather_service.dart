import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
