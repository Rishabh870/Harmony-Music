import 'dart:developer';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:harmonymusic/models/media_Item_builder.dart';
import 'package:harmonymusic/services/music_service.dart';
import 'package:harmonymusic/ui/screens/Library/library_controller.dart';
import 'package:harmonymusic/ui/screens/Playlist/playlist_screen_controller.dart';
import 'package:harmonymusic/ui/widgets/add_to_playlist.dart';
import 'package:hive/hive.dart';
import 'package:on_audio_query_forked/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/playlist.dart';

List<List<dynamic>> rows = [];
String storePlaylistTitle = 'playlist';

final musicServ = Get.find<MusicServices>();
final addToPlayServ = Get.put(AddToPlaylistController());

final RxInt progress = 0.obs;
late int totalRows;

Future<void> importMusicFromTuneMyMusic(BuildContext context) async {
  final RxBool isProcessing = true.obs;
  try {
    // Step 1: Pick the CSV file
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );

    if (result != null && result.files.single.path != null) {
      File csvFile = File(result.files.single.path!);
      String contents = await csvFile.readAsString();

      // Step 2: Convert CSV content to rows
      rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
          .convert(contents);
      totalRows = rows.length - 1;

      // Show progress dialog
      Get.dialog(
        Obx(() => AlertDialog(
              title: const Text("Importing CSV"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: totalRows == 0 ? 0 : progress.value / totalRows,
                  ),
                  const SizedBox(height: 16),
                  Text("Processing ${progress.value} of $totalRows rows"),
                ],
              ),
            )),
        barrierDismissible: false,
      );

      // Step 3: Process rows
      for (int i = 1; i < rows.length; i++) {
        try {
          final row = rows[i];
          final type = row[4];

          switch (type) {
            case 'Favorite':
              print('fav');
              final String songTitle = '${row[0]} ${row[1]}';

              MediaItem? item = await musicServ.searchFirstSongMatch(songTitle);

              await markSongAsFavorite(item!);
              break;

            // case 'Artist':
            //   print('Artist');
            //   break;

            case 'Playlist':
              print('Playlist');
              String playlistId = await checkPlaylistExist(row[3]);

              await addSongToPlaylistFromRow(
                row: row,
                playlistId: playlistId,
                context: context,
              );
              break;

            default:
              print('Unknown type: $type');
              break;
          }

          // Update progress
          progress.value = i; // update progress
          await Future.delayed(Duration(milliseconds: 10)); // yield to UI
        } catch (e) {
          print('Error processing row $i: $e');
        }
      }

      // Step 4: Cleanup
      isProcessing.value = false;
      if (Get.isDialogOpen ?? false) Get.back();
      storePlaylistTitle = 'playlist';

      Get.snackbar(
          'Import Complete', '$totalRows rows processed successfully.');
    } else {
      Get.snackbar('No File Selected', 'Please select a CSV file.');
    }

    if (Hive.isBoxOpen("LibraryPlaylists")) {
      await Hive.box("LibraryPlaylists").close();
    }
  } catch (e) {
    // Handle errors
    Get.snackbar('Error', 'Failed to import music: $e');
  }
}

Future<String> checkPlaylistExist(String playlistTitle) async {
  try {
    final librplstCntrller = Get.find<LibraryPlaylistsController>();
    final playlists = librplstCntrller.libraryPlaylists;

    String? storePlaylistId;

    // Always check if a playlist with this title exists
    for (var playlist in playlists) {
      if (playlist.title == playlistTitle) {
        storePlaylistId = playlist.playlistId;
        break;
      }
    }

    // If not found, create it
    if (storePlaylistId == null) {
      storePlaylistId =
          await createPlaylistFromCsv(playlistTitle: playlistTitle);
    }

    return storePlaylistId;
  } catch (e) {
    print('Failed to check playlists: $e');
    throw ('Failed to check playlists: $e');
  }
}

Future<String> createPlaylistFromCsv({
  required String playlistTitle,
  List<MediaItem>? songItems,
}) async {
  try {
    final String playlistId = "LIB${DateTime.now().millisecondsSinceEpoch}";

    final String thumbnailUrl = (songItems != null && songItems.isNotEmpty)
        ? songItems[0].artUri.toString()
        : Playlist.thumbPlaceholderUrl;

    final newPlaylist = Playlist(
      title: playlistTitle,
      playlistId: playlistId,
      thumbnailUrl: thumbnailUrl,
      description: "Library Playlist",
      isCloudPlaylist: false,
    );

    // ✅ Keep the box open
    Box playlistBox;
    if (Hive.isBoxOpen("LibraryPlaylists")) {
      playlistBox = Hive.box("LibraryPlaylists");
    } else {
      playlistBox = await Hive.openBox("LibraryPlaylists");
    }

    await playlistBox.put(playlistId, newPlaylist.toJson());

    if (songItems != null && songItems.isNotEmpty) {
      Box songBox;
      if (Hive.isBoxOpen(playlistId)) {
        songBox = Hive.box(playlistId);
      } else {
        songBox = await Hive.openBox(playlistId);
      }

      for (MediaItem item in songItems) {
        await songBox.add(MediaItemBuilder.toJson(item));
      }
    }

    final libraryPlaylistsController = Get.find<LibraryPlaylistsController>();
    libraryPlaylistsController.libraryPlaylists.add(newPlaylist);

    return playlistId;
  } catch (e) {
    print('Failed to create playlist from CSV: $e');
    throw ('Failed to create playlist from CSV: $e');
  }
}

Future<void> addSongToPlaylistFromRow({
  required List<dynamic> row,
  required String playlistId,
  required BuildContext context,
}) async {
  try {
    final String songTitle = '${row[0]} ${row[1]}';

    MediaItem? song = await musicServ.searchFirstSongMatch(songTitle);
    if (song != null) {
      await addToPlayServ.addSongsToPlaylist([song], playlistId, context);
    }
  } catch (e) {
    print('Error adding song from row: $e');
  }
}

Future<void> markSongAsFavorite(MediaItem item) async {
  final box = await Hive.openBox("LIBFAV");

  final exists = box.containsKey(item.id);
  if (!exists) {
    box.put(item.id, MediaItemBuilder.toJson(item));

    try {
      final playlistController = Get.find<PlaylistScreenController>(
        tag: const Key("LIBFAV").hashCode.toString(),
      );
      playlistController.addNRemoveItemsinList(item, action: 'add', index: 0);
    } catch (_) {}
  }
}

Future<List<MediaItem>> fetchLocalSongsAsMediaItems() async {
  final audioQuery = OnAudioQuery();

  // Ask permission
  final permissionStatus = await audioQuery.checkAndRequest(retryRequest: true);
  if (!permissionStatus) {
    await Permission.audio.request();
    return [];
  }

  // Query songs
  final List<SongModel> songs = await audioQuery.querySongs();
  // final artworkUri = await audioQuery.queryArtwork(id, type);

  final List<String> dirList = ["/download", "/music"];

  // Convert to MediaItem
  final listOfSongs = songs
      .where((song) =>
          song.data != '' &&
          song.title != '' &&
          dirList.any((dir) => song.data.toLowerCase().contains(dir)))
      .map((song) => MediaItem(
            id: song.data,
            title: song.title,
            artist: song.artist ?? "Unknown Artist",
            album: song.album ?? "Unknown Album",
            duration: Duration(milliseconds: song.duration ?? 0),
            artUri: Uri.file(song.uri ?? ""),
            extras: {"source": "local", 'artId': song.id},
          ))
      .toList();

  log('$listOfSongs');
  return listOfSongs;
}
