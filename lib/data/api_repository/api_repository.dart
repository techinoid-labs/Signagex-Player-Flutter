import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:digital_signage/utils/constants.dart';

class ApiRepository {
  const ApiRepository._();

  static ApiRepository get instance => const ApiRepository._();

  static Future<dynamic> sendPostRequest(
    dynamic requestData,
    String port,
    String url,
    String? authToken,
  ) async {
    String apiUrl = '$baseurl$port$url';
print(apiUrl);
    try {
      http.Response response = await http
          .post(
            Uri.parse(apiUrl),
            headers: authToken != null
                ? {
                    HttpHeaders.contentTypeHeader: 'application/json',
                    HttpHeaders.authorizationHeader: "Bearer $authToken"
                  }
                : {HttpHeaders.contentTypeHeader: 'application/json'},
            body: json.encode(requestData),
          )
          .timeout(const Duration(seconds: 30));
      return json.decode(response.body);
    } on TimeoutException {
      return {
        "statusCode": 500,
        "message": "Request Timeout",
      };
    } catch (error) {
      print(error);
      return {
        "statusCode": 400,
        "message": "No internet connection",
      };
    }
  }

  static Future<dynamic> sendGetRequest(
    String port,
    String url,
    String? authToken,
  ) async {
    String apiUrl = '$url$port$url';

    try {
      http.Response response = await http
          .get(
            Uri.parse(apiUrl),
            headers: authToken != null
                ? {
                    HttpHeaders.contentTypeHeader: 'application/json',
                    HttpHeaders.authorizationHeader: "Bearer $authToken"
                  }
                : {HttpHeaders.contentTypeHeader: 'application/json'},
          )
          .timeout(const Duration(seconds: 30));

      return json.decode(response.body);
    } on TimeoutException {
      return {
        "statusCode": 500,
        "message": "Request Timeout",
      };
    } catch (error) {
      return {
        "statusCode": 400,
        "message": "No internet connection",
      };
    }
  }

  static Future<dynamic> sendPatchRequest(
    dynamic requestData,
    String port,
    String url,
    String? authToken,
  ) async {
    String apiUrl = '$url$port$url';

    try {
      http.Response response = await http
          .patch(
            Uri.parse(apiUrl),
            headers: authToken != null
                ? {
                    HttpHeaders.contentTypeHeader: 'application/json',
                    HttpHeaders.authorizationHeader: "Bearer $authToken"
                  }
                : {HttpHeaders.contentTypeHeader: 'application/json'},
            body: json.encode(requestData),
          )
          .timeout(const Duration(seconds: 30));
      return json.decode(response.body);
    } on TimeoutException {
      return {
        "statusCode": 500,
        "message": "Request Timeout",
      };
    } catch (e) {
      print(e);
      return {
        "statusCode": 400,
        "message": "No internet connection",
      };
    }
  }

  static Future<dynamic> sendDeleteRequest(
    String port,
    String url,
    String? authToken,
  ) async {
    String apiUrl = '$url$port$url';

    try {
      http.Response response = await http
          .delete(
            Uri.parse(apiUrl),
            headers: authToken != null
                ? {
                    HttpHeaders.contentTypeHeader: 'application/json',
                    HttpHeaders.authorizationHeader: "Bearer $authToken"
                  }
                : {HttpHeaders.contentTypeHeader: 'application/json'},
          )
          .timeout(const Duration(seconds: 30));
      return json.decode(response.body);
    } on TimeoutException {
      return {
        "statusCode": 500,
        "message": "Request Timeout",
      };
    } catch (e) {
      print(e);
      return {
        "statusCode": 400,
        "message": "No internet connection",
      };
    }
  }
}
