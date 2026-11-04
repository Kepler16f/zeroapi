import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/model_identity.dart';
import 'package:zeroapi/gateway/openrouter_pricing.dart';

class _HangingGetUrlClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      Completer<HttpClientRequest>().future;

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('identity strips provider prefix and terminal free only', () {
    expect(ModelIdentity.normalize('OpenAI/GPT-5-free'), 'gpt-5');
    expect(ModelIdentity.normalize('GPT-5-freeish'), 'gpt-5-freeish');
    expect(ModelIdentity.matches('vendor/foo-free', 'foo'), isTrue);
    expect(ModelIdentity.matches('vendor/foo-2', 'foo'), isFalse);
  });

  test('estimates known prices, excludes cache token double charge', () async {
    final dir = await Directory.systemTemp.createTemp('or-pricing-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/cache.json');
    await file.writeAsString(jsonEncode({
      'fetchedAt': DateTime.utc(2026).toIso8601String(),
      'models': {
        'acme/foo': {'prompt': '0.00001', 'completion': '0.00002',
          'input_cache_read': '0.000001', 'input_cache_write': '0.00003'}
      }
    }));
    final pricing = OpenRouterPricing(cacheFile: file);
    expect(await pricing.loadCache(), isTrue);
    final result = pricing.estimate('foo-free', promptTokens: 100,
      completionTokens: 20, cachedPromptTokens: 40);
    expect(result.usd, closeTo(0.0006 + 0.00004 + 0.0004, 1e-12));
    expect(result.isPartial, isFalse);
    final withWrite = pricing.estimate('acme/foo', promptTokens: 100,
      completionTokens: 0, cachedPromptWriteTokens: 10);
    expect(withWrite.usd, closeTo(90 * 0.00001 + 10 * 0.00003, 1e-12));
  });

  test('missing fields and ambiguous normalized matches remain unknown/partial', () async {
    final dir = await Directory.systemTemp.createTemp('or-pricing-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/cache.json');
    await file.writeAsString(jsonEncode({'models': {
      'one/foo': {'prompt': '0.1'},
      'two/foo': {'prompt': '0.2', 'completion': '0.3'},
    }}));
    final pricing = OpenRouterPricing(cacheFile: file);
    await pricing.loadCache();
    expect(pricing.estimate('foo', promptTokens: 1, completionTokens: 1).usd, isNull);
    final unknown = pricing.estimate('unlisted', promptTokens: 1, completionTokens: 1);
    expect(unknown.unknownModel, isTrue);
    expect(unknown.usd, isNull);
    final partial = pricing.estimate('one/foo', promptTokens: 2, completionTokens: 3);
    expect(partial.usd, closeTo(0.2, 1e-12));
    expect(partial.isPartial, isTrue);
  });

  test('missing cached prices use regular rate without an assumed discount', () async {
    final dir = await Directory.systemTemp.createTemp('or-pricing-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/cache.json');
    await file.writeAsString(jsonEncode({'models': {
      'acme/foo': {'prompt': '0.1', 'completion': '0.2'},
    }}));
    final pricing = OpenRouterPricing(cacheFile: file);
    await pricing.loadCache();
    final result = pricing.estimate('acme/foo', promptTokens: 10,
      completionTokens: 0, cachedPromptTokens: 6);
    expect(result.usd, closeTo(1.0, 1e-12));
    expect(result.isPartial, isTrue);
  });

  test('invalid prices are unknown and cached token counts cannot exceed totals', () async {
    final dir = await Directory.systemTemp.createTemp('or-pricing-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/cache.json');
    await file.writeAsString(jsonEncode({'models': {
      'acme/foo': {'prompt': '-1', 'completion': 'Infinity',
        'input_cache_read': 'NaN'},
      'acme/bar': {'prompt': '0.1', 'completion': '0.2',
        'input_cache_read': '0.01', 'input_cache_write': '0.03'},
    }}));
    final pricing = OpenRouterPricing(cacheFile: file);
    await pricing.loadCache();
    expect(pricing.priceFor('acme/foo')!.prompt, isNull);
    expect(pricing.priceFor('acme/foo')!.completion, isNull);
    final invalid = pricing.estimate('acme/foo', promptTokens: 2, completionTokens: 1);
    expect(invalid.usd, isNull);
    expect(invalid.isPartial, isTrue);
    final clamped = pricing.estimate('acme/bar', promptTokens: 10,
      completionTokens: 0, cachedPromptTokens: 20, cachedPromptWriteTokens: 20);
    expect(clamped.usd, closeTo(0.1, 1e-12));
    expect(clamped.isPartial, isFalse);
    final negative = pricing.estimate('acme/bar', promptTokens: -10,
      completionTokens: -5, cachedPromptTokens: 3);
    expect(negative.usd, 0);
    expect(negative.isPartial, isFalse);
  });

  test('getUrl and response body have independent timeouts', () async {
    final pending = OpenRouterPricing(httpClient: _HangingGetUrlClient(),
      requestTimeout: const Duration(milliseconds: 20));
    expect(await pending.refresh(), isFalse);

    final server = await HttpServer.bind('127.0.0.1', 0);
    final neverFinish = Completer<void>();
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"data":[');
      await request.response.flush();
      await neverFinish.future;
    });
    final bodyStall = OpenRouterPricing(
      catalog: Uri.parse('http://127.0.0.1:${server.port}/models'),
      responseTimeout: const Duration(milliseconds: 30),
    );
    try {
      expect(await bodyStall.refresh(), isFalse);
    } finally {
      neverFinish.complete();
      await server.close(force: true);
    }
  });

}
