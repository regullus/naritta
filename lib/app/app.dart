import 'package:flutter/material.dart';

import '../core/platform_info.dart';
import 'router.dart';
import 'theme.dart';

class NarittaApp extends StatelessWidget {
  const NarittaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Naritta',
      debugShowCheckedModeBanner: false,
      theme: NarittaTheme.dark,
      routerConfig: router,
      builder: (context, child) {
        // Detect TV mode from the first MediaQuery context
        PlatformInfo.detectFromContext(context);
        return child ?? const SizedBox.shrink();
      },
    );
  }
}
