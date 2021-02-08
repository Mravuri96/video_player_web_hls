import 'dart:async' show Future, Stream, StreamController;
import 'dart:html' show DomException, Event, TimeRanges, VideoElement;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show HtmlElementView, Size, Widget;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_plugins/flutter_web_plugins.dart' show Registrar;
import 'package:js/js.dart' show allowInterop;
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    show
        DataSource,
        DataSourceType,
        DurationRange,
        VideoEvent,
        VideoEventType,
        VideoPlayerPlatform;

import 'hls.dart' show Hls, isSupported;
import 'no_script_tag_exception.dart' show NoScriptTagException;

// An error code value to error name Map.
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/code
const Map<int, String> _kErrorValueToErrorName = {
  1: 'MEDIA_ERR_ABORTED',
  2: 'MEDIA_ERR_NETWORK',
  3: 'MEDIA_ERR_DECODE',
  4: 'MEDIA_ERR_SRC_NOT_SUPPORTED',
};

// An error code value to description Map.
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/code
const Map<int, String> _kErrorValueToErrorDescription = {
  1: 'The user canceled the fetching of the video.',
  2: 'A network error occurred while fetching the video, despite having previously been available.',
  3: 'An error occurred while trying to decode the video, despite having previously been determined to be usable.',
  4: 'The video has been found to be unsuitable (missing or in a format not supported by your browser).',
  5: 'Could not load manifest'
};

// The default error message, when the error is an empty string
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/message
const String _kDefaultErrorMessage =
    'No further diagnostic information can be determined or provided.';

/// The web implementation of [VideoPlayerPlatform].
///
/// This class implements the `package:video_player` functionality for the web.
class VideoPlayerPluginHls extends VideoPlayerPlatform {
  /// Registers this class as the default instance of [VideoPlayerPlatform].
  static void registerWith(Registrar registrar) {
    VideoPlayerPlatform.instance = VideoPlayerPluginHls();
  }

  final Map<int, _VideoPlayer> _videoPlayers = <int, _VideoPlayer>{};

  int _textureCounter = 1;

  @override
  Future<void> init() async {
    return _disposeAllPlayers();
  }

  @override
  Future<void> dispose(int textureId) async {
    _videoPlayers[textureId]!.dispose();
    _videoPlayers.remove(textureId);
  }

  void _disposeAllPlayers() {
    _videoPlayers.values
        .forEach((_VideoPlayer videoPlayer) => videoPlayer.dispose());
    _videoPlayers.clear();
  }

  @override
  Future<int> create(DataSource dataSource) async {
    final textureId = _textureCounter;
    _textureCounter++;

    String? uri;
    switch (dataSource.sourceType) {
      case DataSourceType.network:
        // Do NOT modify the incoming uri, it can be a Blob, and Safari doesn't
        // like blobs that have changed.
        uri = dataSource.uri;
        break;
      case DataSourceType.asset:
        var assetUrl = dataSource.asset;
        if (dataSource.package != null && dataSource.package!.isNotEmpty) {
          assetUrl = 'packages/${dataSource.package}/$assetUrl';
        }
        // 'webOnlyAssetManager' is only in the web version of dart:ui
        // ignore: undefined_prefixed_name
        assetUrl = ui.webOnlyAssetManager.getAssetUrl(assetUrl);
        uri = assetUrl;
        break;
      case DataSourceType.file:
        return Future.error(UnimplementedError(
            'web implementation of video_player cannot play local files'));
    }

    final player = _VideoPlayer(
      uri: uri,
      textureId: textureId,
    )..initialize();

    _videoPlayers[textureId] = player;
    return textureId;
  }

  @override
  Future<void> setLooping(int textureId, bool looping) async {
    return _videoPlayers[textureId]!.setLooping(looping);
  }

  @override
  Future<void> play(int textureId) async {
    return _videoPlayers[textureId]!.play();
  }

  @override
  Future<void> pause(int textureId) async {
    return _videoPlayers[textureId]!.pause();
  }

  @override
  Future<void> setVolume(int textureId, double volume) async {
    return _videoPlayers[textureId]!.setVolume(volume);
  }

  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) async {
    assert(speed > 0);

    return _videoPlayers[textureId]!.setPlaybackSpeed(speed);
  }

  @override
  Future<void> seekTo(int textureId, Duration position) async {
    return _videoPlayers[textureId]!.seekTo(position);
  }

  @override
  Future<Duration> getPosition(int textureId) async {
    _videoPlayers[textureId]!.sendBufferingUpdate();
    return _videoPlayers[textureId]!.getPosition();
  }

  @override
  Stream<VideoEvent> videoEventsFor(int textureId) {
    return _videoPlayers[textureId]!.eventController.stream;
  }

  @override
  Widget buildView(int textureId) {
    return HtmlElementView(viewType: 'videoPlayer-$textureId');
  }
}

class _VideoPlayer {
  _VideoPlayer({this.uri, this.textureId});

  final StreamController<VideoEvent> eventController =
      StreamController<VideoEvent>();

  bool isInitialized = false;
  final int? textureId;
  final String? uri;
  VideoElement? videoElement;

  void initialize() {
    videoElement = VideoElement()
      ..src = uri!
      ..autoplay = true
      ..controls = true
      ..style.border = 'none'
      // Allows Safari iOS to play the video inline
      ..setAttribute('playsinline', 'true');

    // TODO(hterkelsen): Use initialization parameters once they are available
    // ignore: undefined_prefixed_name
    ui.platformViewRegistry.registerViewFactory(
        'videoPlayer-$textureId', (int viewId) => videoElement);
    if (videoElement!.canPlayType('application/vnd.apple.mpegurl') != '' &&
        videoElement!.canPlayType('video/mp4') != '' &&
        videoElement!.canPlayType('video/webm') != '') {
      videoElement!
        ..src = uri.toString()
        ..addEventListener('loadedmetadata', (_) {
          if (!isInitialized) {
            isInitialized = true;
            sendInitialized();
          }
        });
    } else if (isSupported() && uri.toString().contains('m3u8')) {
      try {
        final hls = Hls();
        hls
          ..attachMedia(videoElement)
          ..on('hlsMediaAttached', allowInterop((_, __) {
            hls.loadSource(uri.toString());
          }))
          ..on('hlsError', allowInterop((_, data) {
            eventController.addError(PlatformException(
              code: _kErrorValueToErrorName[2]!,
              message: _kDefaultErrorMessage,
              details: _kErrorValueToErrorDescription[5],
            ));
          }));
        videoElement!.onCanPlay.listen((_) {
          if (!isInitialized) {
            isInitialized = true;
            sendInitialized();
          }
        });
      } on NoScriptTagException {
        throw NoScriptTagException();
      }
    } else {
      videoElement!
        ..src = uri.toString()
        ..addEventListener('loadedmetadata', (_) {
          if (!isInitialized) {
            isInitialized = true;
            sendInitialized();
          }
        });
    }

    // The error event fires when some form of error occurs while attempting to load or perform the media.
    videoElement!.onError.listen((Event _) {
      // The Event itself (_) doesn't contain info about the actual error.
      // We need to look at the HTMLMediaElement.error.
      // See: https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/error
      final error = videoElement!.error!;
      eventController.addError(PlatformException(
        code: _kErrorValueToErrorName[error.code]!,
        message: error.message != '' ? error.message : _kDefaultErrorMessage,
        details: _kErrorValueToErrorDescription[error.code],
      ));
    });

    videoElement!.onEnded.listen((_) {
      eventController.add(VideoEvent(eventType: VideoEventType.completed));
    });
  }

  void sendBufferingUpdate() {
    eventController.add(VideoEvent(
      buffered: _toDurationRange(videoElement!.buffered),
      eventType: VideoEventType.bufferingUpdate,
    ));
  }

  Future<void> play() {
    return videoElement!.play().catchError((e) {
      // play() attempts to begin playback of the media. It returns
      // a Promise which can get rejected in case of failure to begin
      // playback for any reason, such as permission issues.
      // The rejection handler is called with a DomException.
      // See: https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/play
      final exception = e;
      eventController.addError(PlatformException(
        code: exception.name,
        message: exception.message,
      ));
    }, test: (e) => e is DomException);
  }

  void pause() {
    videoElement!.pause();
  }

  void setLooping(bool value) {
    videoElement!.loop = value;
  }

  void setVolume(double value) {
    if (value > 0.0) {
      videoElement!.muted = false;
    } else {
      videoElement!.muted = true;
    }
    videoElement!.volume = value;
  }

  void setPlaybackSpeed(double speed) {
    assert(speed > 0, 'Playback has to be greater than 0');

    videoElement!.playbackRate = speed;
  }

  void seekTo(Duration position) {
    videoElement!.currentTime = position.inMilliseconds.toDouble() / 1000;
  }

  Duration getPosition() {
    return Duration(milliseconds: (videoElement!.currentTime * 1000).round());
  }

  void sendInitialized() {
    eventController.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: Duration(
          milliseconds: (videoElement!.duration * 1000).round(),
        ),
        size: Size(
          videoElement!.videoWidth.toDouble() ?? 0.0,
          videoElement!.videoHeight.toDouble() ?? 0.0,
        ),
      ),
    );
  }

  void dispose() {
    videoElement!
      ..removeAttribute('src')
      ..load();
  }

  List<DurationRange> _toDurationRange(TimeRanges buffered) {
    final durationRange = <DurationRange>[];
    for (var i = 0; i < buffered.length; i++) {
      durationRange.add(DurationRange(
        Duration(milliseconds: (buffered.start(i) * 1000).round()),
        Duration(milliseconds: (buffered.end(i) * 1000).round()),
      ));
    }
    return durationRange;
  }
}
