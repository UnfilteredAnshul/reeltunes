import 'package:flutter_test/flutter_test.dart';

import 'package:reel_tune/link_rules.dart';

void main() {
  group('linkProblem', () {
    test('accepts the four supported short links', () {
      expect(linkProblem('https://youtube.com/shorts/abc123'), isNull);
      expect(linkProblem('https://youtu.be/abc123'), isNull);
      expect(linkProblem('https://www.instagram.com/reel/abc123/'), isNull);
      expect(linkProblem('https://www.facebook.com/reel/123456'), isNull);
      expect(linkProblem('https://vt.tiktok.com/ZSabc123/'), isNull);
    });

    test('refuses long-form YouTube and non-https links', () {
      expect(linkProblem('https://youtube.com/watch?v=abc'), isNotNull);
      expect(linkProblem('http://youtu.be/abc123'), isNotNull);
    });

    test('asks for a link when the box is empty', () {
      expect(linkProblem('   '), 'Paste a link first');
    });
  });
}
