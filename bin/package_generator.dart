library dartdocorg.bin.package_generator;

import 'dart:io';

import 'package:args/args.dart';
import 'package:dartdocorg/config.dart';
import 'package:dartdocorg/generators/package_generator.dart';
import 'package:dartdocorg/logging.dart' as logging;
import 'package:dartdocorg/package.dart';
import 'package:dartdocorg/pub_retriever.dart';
import 'package:dartdocorg/shard.dart';
import 'package:dartdocorg/storage.dart';
import 'package:dartdocorg/datastore_retriever.dart';
import 'package:dartdocorg/uploaders/package_uploader.dart';
import 'package:logging/logging.dart';
import 'package:dartdocorg/cleaners/package_cleaner.dart';
import 'package:dartdocorg/datastore.dart';
import 'dart:async';
import 'dart:math';
import 'package:dartdocorg/version.dart';
import 'package:dartdocorg/cleaners/cdn_cleaner.dart';

class _PackageGenerator {
  final Config config;
  final PubRetriever pubRetriever;
  final Storage storage;
  final Datastore datastore;
  final DatastoreRetriever datastoreRetriever;
  final PackageGenerator generator;
  final PackageCleaner packageCleaner;
  final CdnCleaner cdnCleaner;
  final PackageUploader uploader;

  int docsVersion;

  _PackageGenerator(this.config, this.pubRetriever, this.storage, this.datastore, this.datastoreRetriever,
      this.generator, this.packageCleaner, this.cdnCleaner, this.uploader);

  factory _PackageGenerator.build(String dirroot) {
    var config = new Config.buildFromFiles(dirroot, "config.yaml", "credentials.yaml");
    var pubRetriever = new PubRetriever();
    var storage = new Storage(config);
    var datastore = new Datastore(config);
    var storageRetriever = new DatastoreRetriever(datastore);
    var generator = new PackageGenerator(config);
    var packageCleaner = new PackageCleaner(config);
    var cdnCleaner = new CdnCleaner(config);
    var uploader = new PackageUploader(config, storage);
    return new _PackageGenerator(
        config, pubRetriever, storage, datastore, storageRetriever, generator, packageCleaner, cdnCleaner, uploader);
  }

  Future<Null> initialize() async {
    this.docsVersion = await datastore.docsVersion();
  }

  Future<Iterable<Package>> retrieveNextPackages() async {
    List<Package> allPackages = (await pubRetriever.update());
    await datastoreRetriever.update(docsVersion);
    var allDataStorePackages = datastoreRetriever.allPackages;
    allPackages.removeWhere((p) => allDataStorePackages.contains(p));
    _logger.info("The number of the new packages - ${allPackages.length}");
    var shard = await getShard(config);
    _logger.info("Shard: $shard");
    var shardedPackages = shard.part(allPackages);
    return shardedPackages.getRange(0, min(20, shardedPackages.length));
  }

  Future<Null> handlePackages(Iterable<Package> packages) async {
    packageCleaner.deleteSync();
    var erroredPackages = await generator.generate(packages);
    var successfulPackages = packages.toSet()..removeAll(erroredPackages);
    await uploader.uploadSuccessfulPackages(successfulPackages);
    _logger.info("Marking successful packages in datastore");
    await Future.wait(successfulPackages.map((package) async {
      return datastore.upsert(package, docsVersion, status: "success");
    }));
    await uploader.uploadErroredPackages(erroredPackages);
    _logger.info("Marking errored packages in datastore");
    await Future.wait(erroredPackages.map((package) async {
      return datastore.upsert(package, docsVersion, status: "error");
    }));
  }
}

main(List<String> args) async {
  try {
    var parser = new ArgParser();
    parser.addOption('name', help: "If specified (together with --version) - will regenerate that package");
    parser.addOption('version', help: "If specified (together with --name) - will regenerate that package");
    parser.addOption('dirroot', help: "Specify the application directory, if not current");
    parser.addFlag('help', negatable: false, help: "Show help");
    var argsResults = parser.parse(args);
    if (argsResults["help"]) {
      print("Generates packages and uploads them to GCS, in an infinite loop. "
          "Basically, the main script of the app, which does all the important work.\n");
      print(parser.usage);
      exit(0);
    }
    logging.initialize();
    var packageGenerator = new _PackageGenerator.build(argsResults["dirroot"]);

    if (argsResults["name"] != null && argsResults["version"] != null) {
      await packageGenerator.initialize();
      var package = new Package(argsResults["name"], new Version(argsResults["version"]));
      await packageGenerator.handlePackages([package]);
      exit(0);
    } else {
      while (true) {
        await packageGenerator.initialize();
        var packages = await packageGenerator.retrieveNextPackages();
        if (packages.isNotEmpty) {
          await packageGenerator.handlePackages(packages);
        } else {
          _logger.info("Sleeping for 3 minutes...");
          await new Future.delayed(new Duration(minutes: 3));
        }
      }
    }
  } catch (error, stackTrace) {
    print(error);
    print(stackTrace);
    exit(1);
  }
}

Logger _logger = new Logger("dartdocorg");
