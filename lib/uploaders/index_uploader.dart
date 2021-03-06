library dartdocorg.index_uploader;

import 'dart:async';
import 'dart:io';

import 'package:dartdocorg/config.dart';
import 'package:dartdocorg/generators/index_generator.dart';
import 'package:dartdocorg/storage.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

Logger _logger = new Logger("index_uploader");

class IndexUploader {
  final Config config;
  final Storage storage;
  IndexUploader(this.config, this.storage);

  Future<Null> uploadIndexFiles() async {
    _logger.info("Uploading index files...");
    await storage.insertFile("404.html", new File(p.join(config.outputDir, "404.html")));
    await Future.wait(allIndexUrls.map((url) {
      return storage.insertFile(url, new File(p.join(config.outputDir, url)), maxAge: 60);
    }));
  }
}
