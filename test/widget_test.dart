import 'package:flutter_test/flutter_test.dart';

import 'package:reel_tune/main.dart';

void main() {
  testWidgets('app boots to library', (tester) async {
    await tester.pumpWidget(const ReelTuneApp());
    expect(find.text('ReelTune'), findsOneWidget);
  });
}
