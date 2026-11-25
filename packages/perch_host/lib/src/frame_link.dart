// What carries one app connection's frames to the server: a LAN WebSocket, or one device
// multiplexed over the relay connection. The server runs the encrypted channel on top.
import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

abstract class FrameLink {
  /// Binary frames from the app. Text frames are surfaced as [String] (a phase 1 app).
  Stream<Object> get frames;

  /// Sends one binary frame.
  void send(Uint8List frame);

  /// Sends one text frame (only for telling a phase 1 app to pair again).
  void sendText(String text);

  /// Closes the connection.
  void close();

  /// Where it comes from, for logs (an IP address, or `relay`).
  String get address;
}

/// A direct WebSocket from the LAN.
class WebSocketFrameLink implements FrameLink {
  final WebSocketChannel channel;
  @override
  final String address;
  WebSocketFrameLink(this.channel, this.address);

  @override
  Stream<Object> get frames => channel.stream.map<Object>((f) => f is String
      ? f
      : f is Uint8List
          ? f
          : Uint8List.fromList((f as List).cast<int>()));

  @override
  void send(Uint8List frame) {
    try {
      channel.sink.add(frame);
    } catch (_) {}
  }

  @override
  void sendText(String text) {
    try {
      channel.sink.add(text);
    } catch (_) {}
  }

  @override
  void close() {
    try {
      channel.sink.close();
    } catch (_) {}
  }
}
