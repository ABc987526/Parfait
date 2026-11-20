import 'dart:convert';

import 'package:http/http.dart' as http;

/// A JSON answer of [body], the way the pixiv API responds.
http.Response jsonResponse(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);
