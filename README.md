# Dartdocs.org generator

This is a bunch of scripts, which generate Dartdocs.org contents, for every single package in [pub](https://pub.dartlang.org/).

## Install

It runs on Google Compute Engine instances, and designed to be run there. You still can run it on your local machine,
in this case you'll need to create credentials.yaml file with the credentials, which allow access to Dartdocs project
in Google Cloud and also to the dartdocs' account on CloudFlare CDN. Check out credentials.yaml.example for the example.

Unfortunately (or, fortunately :)) you cannot do anything with http://www.dartdocs.org without the credentials.

But once you got them, the rest is simple (if you have Dart already installed):

```
git clone https://github.com/astashov/dartdocorg.git
cd dartdocorg
pub get
```

Now, copy your credentials to credentials.yaml, and you are good to go.

## Dart Scripts

It has several scripts, which you can use to control the generation of docs. All scripts support `--help` arg, which
will tell you more about the supported arguments.

* `bin/package_generator.dart`

That's the main one, it generates documentation for the packages from pub. It downloads the list of available packages
from pub, installs them, generates the documentation, and uploads it to Google Cloud Storage. Doing that in batches.

It also supports "sharding". If there are several instances running in the same Compute Engine Instance Group, you can
specify the name of the group in `config.yaml`, and then they will split the work between the instances. So, if you
need to regenerate the docs for the whole pub quickly, you can run 100 instances within the same group, and it probably
will be done in several hours.

It also stores all the meta information about the packages to Google Datastore (like, the status of generation (success
or error), when it was generated, etc).

It also can regenerate specific package/version, check `--help` for details.

* `bin/index_generator.dart`

Using all the meta information from Google Datastore, stored by `package_generator.dart`, it builds index pages and
uploads them to Google Cloud Storage as well. Like, index.html page with all the successfully generated packages,
'failures' page with links to logs of failures, 'history' page with the latest generated packages, its status and
links to logs as well.

* `bin/purge_cdn_cache.dart`

It just sends a command via CloudFront API to clear all the cache on CloudFront. Useful when you regenerate the whole
site with the new version of dartdoc, for example.

* `bin/bump_docs_version.dart`

We have a global variable 'docsVersion', which is stored in Datastore, and also every single meta record in Datastore
has a field with that value. It's an integer, which is just a timestamp. When the package's docsVersion value is equal
to the global docsVersion value, we consider it generated (with success or error). When they are not equal, the package
docs will be regenerated again. So, `bin/bump_docs_version.dart` just bumps global docsVersion to the current timestamp.
Which means all the packages will be stale, and will be regenerated again. That's useful when you need to regenerate
all the packages with the new version of dartdocs, for example.

## Shell scripts

There are also some shell scripts, which we use to run the app

* create_google_cloud_project.sh

It configures Google Cloud project to run dartdocorg. It adds indexes to Datastore, creates the bucket, creates instance
templates and run instances in instance groups.

* {index,package}_generator_boot.sh

This is a startup script for the index and package instances, it provisions the instances:

- Installs latest Dart SDK
- Clones and configures the app
- Creates credentials.yaml
- Configures monit to restart the script if it crashes
- Configures log rotation

* {index,package}_generator_monit.sh

This is the script, which is used by monit to start, stop and restart the Dart scripts.

## Cloud architecture

It uses:

* Google Compute Engine - to run `bin/package_generator.dart` and `bin/index_generator.dart`. There are 2 instance
  groups where these scripts run - **dartdocs-package-generators** and **dartdocs-index-generators** accordingly.
  **dartdocs-index-generators** is supposed to have only one running instance, which will rebuild the index pages.
  **dartdocs-package-generators** can have any number of running instances, depending on the work load and how fast
  you want to regenerate the documentation.

  Both have startup scripts, which are run on an instance launch. They install Dart, clone the repo, configure monit
  and log rotation, and finally start the `bin/` scripts. You can find templates for them in the files `package_generator_boot.sh`
  `index_generator_boot.sh`.

  To control the number of running instances per group from CLI, you can use the following commands:

```bash
$ gcloud compute instance-groups managed resize dartdocs-index-generators --size 1 --zone us-central1-f
$ gcloud compute instance-groups managed resize dartdocs-package-generators --size 4 --zone us-central1-f
```

* Google Cloud Datastore - to store all the meta information about packages (status, updatedAt, docsVersion, etc).
  It also has custom composite indexes defined in `index.yaml`. To load the indexes to the Datastore from CLI, use
  the following command:

```bash
$ gcloud preview datastore create-indexes index.yaml
```

To remove old unused instances:

```bash
$ gcloud preview datastore cleanup-indexes index.yaml
```

* Google Cloud Storage - to store all the documentation and index packages. It's configured to serve it as a static
  site.

* CloudFront CDN - to add SSL support and the redirect from http://dartdocs.org to http://www.dartdocs.org

## Common tasks

* Regenerate the docs with the new version of dartdoc

The instances install the latest dev SDK on boot, (check out the `{index,package}_generator_boot.sh` script).
So, to upgrade to the new version of dartdoc, we need to restart the instances and scale them up.
We also need to run `bin/bump_docs_version.dart` to update `docsVersion` and purge the CDN cache for the package docs.

So, you have to do:

```bash
$ gcloud compute instance-groups managed resize dartdocs-package-generators --size 0 --zone us-central1-f
$ dart bin/bump_docs_version.dart
$ gcloud compute instance-groups managed resize dartdocs-package-generators --size 11 --zone us-central1-f
... after its done ...
$ dart bin/purge_cdn_cache.dart
```

So, the command `gcloud compute instance-groups managed resize dartdocs-package-generators --size 11 --zone us-central1-f`
sets the number of instances in dartdocs-package-generators group according to the `--size` argument.
By default, you only can launch 24 CPU units per google cloud project, so, by default we are limited with 11 instances.

It takes ~20-24 hours to regenerate the whole pub with 11 instances.

It doesn't scale down automatically, you have to use the command
`gcloud compute instance-groups managed resize dartdocs-package-generators --size 1 --zone us-central1-f`
to scale it back to one instance once they are done with regenerating everything.

* Regenerate just one specific package

Just simply run:

```bash
$ dart bin/package_generator.dart --name blah --version 1.2.3
```

And it will regenerate the package and override it on the https://www.dartdocs.org.
