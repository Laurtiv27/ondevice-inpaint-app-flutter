import 'package:flutter/material.dart';
import 'package:ondevice_inpaint_app/ui/editor_page.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Inpaint Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0E3B2D),
        colorScheme: const ColorScheme.dark().copyWith(
          primary: const Color(0xFF3DAE7A),
          secondary: const Color(0xFF2E7D55),
          surface: const Color(0xFF0E3B2D),
        ),
      ),
      home: const EditorPage(),
    );
  }
}
