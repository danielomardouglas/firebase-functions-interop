// Copyright (c) 2017, Anatoly Pulyaevskiy. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

/// Interop library for Firebase Functions NodeJS SDK.
///
/// This library defines bindings to JavaScript APIs exposed by official Firebase
/// Functions library for NodeJS, therefore it can't be used on it's own. It
/// must be compiled to JavaScript and run under NodeJS runtime.
///
/// Use [firebaseFunctions] object as main entry point.
///
/// To create your cloud function use corresponding namespaces on this object:
///
/// - [firebaseFunctions.https] for creating HTTPS functions
/// - [firebaseFunctions.database] for creating Realtime Database functions
///
/// Here is an example of creating and exporting an HTTPS function:
///
///     import 'package:firebase_functions_interop/firebase_functions_interop.dart';
///
///     void main() {
///       // Registers helloWorld function under path prefix `/hello-world`
///       firebaseFunctions['hello-world'] = firebaseFunctions.https
///         .onRequest(helloWorld);
///     }
///
///     // Simple function which returns a response with a body containing
///     // "Hello world".
///     void helloWorld(HttpRequest request) {
///       request.response.writeln("Hello world");
///       request.response.close();
///     }
library firebase_functions_interop;

import 'dart:async';
import 'dart:js';

import 'package:built_value/serializer.dart';
import 'package:firebase_admin_interop/firebase_admin_interop.dart';
import 'package:firebase_admin_interop/js.dart' as admin;
import 'package:node_interop/http.dart';
import 'package:node_interop/node_interop.dart';

import 'src/bindings.dart' as js;

export 'package:node_interop/http.dart' show HttpRequest;

export 'src/bindings.dart' show CloudFunction, HttpsFunction;

final FirebaseFunctions firebaseFunctions = new FirebaseFunctions._();

/// Global namespace from which all Firebase Cloud Functions can be accessed.
class FirebaseFunctions {
  final Config config = new Config();
  final Https https = new Https._();
  final Database database = new Database._();

  FirebaseFunctions._() {
    js.initFirebaseFunctions();
  }

  /// Export [function] under specified [key].
  ///
  /// For HTTPS functions the [key] defines URL path prefix.
  operator []=(String key, dynamic function) {
    assert(function is js.HttpsFunction || function is js.CloudFunction);
    node.export(key, function);
  }
}

/// Provides access to environment configuration of Firebase Functions.
///
/// See also:
/// - [https://firebase.google.com/docs/functions/config-env](https://firebase.google.com/docs/functions/config-env)
class Config {
  js.Config _config;
  js.Config get nativeInstance => _config ??= js.config();

  /// Returns configuration value specified by it's [key].
  ///
  /// This method expects keys to be fully qualified (namespaced), e.g.
  /// `some_service.client_secret` or `some_service.url`.
  /// This is different from native JS implementation where namespaced
  /// keys are broken into nested JS object structure, e.g.
  /// `functions.config().some_service.client_secret`.
  dynamic get(String key) {
    if (key == 'firebase') {
      return nativeInstance.firebase;
    }
    var data = _cache ??= dartify(nativeInstance);
    var parts = key.split('.');
    var value;
    for (var subKey in parts) {
      if (data is! Map) return null;
      value = data[subKey];
      if (value == null) break;
      data = value;
    }
    return value;
  }

  Map<String, dynamic> _cache;

  /// Firebase-specific configuration which can be used to initialize
  /// Firebase Admin SDK.
  ///
  /// This is a shortcut for calling `get('firebase')`.
  admin.AppOptions get firebase => get('firebase');
}

/// HTTPS functions namespace.
class Https {
  Https._();

  /// Event [handler] which is run every time an HTTPS URL is hit.
  ///
  /// Returns a [js.HttpsFunction] which can be exported.
  ///
  /// The event handler is called with single [request] argument, instance
  /// of [HttpRequest] interface from `dart:io`. This object acts as a
  /// proxy to JavaScript request and response objects.
  ///
  /// If you need access to native objects use [HttpRequest.nativeStream] and
  /// [HttpResponse.nativeStream] :
  ///
  ///     void handler(HttpRequest request) {
  ///       IncomingMessage nativeRequest = request.nativeStream;
  ///       ServerResponse nativeResponse = request.response.nativeStream;
  ///     }
  js.HttpsFunction onRequest(handler(HttpRequest request)) {
    void jsHandler(IncomingMessage request, ServerResponse response) {
      var requestProxy = new HttpRequest(request, response);
      handler(requestProxy);
    }

    return js.onRequest(allowInterop(jsHandler));
  }
}

/// Realtime Database functions namespace.
class Database {
  Database._();

  /// Returns reference builder for specified [path].
  RefBuilder ref(String path) => new RefBuilder._(js.ref(path));
}

/// The Firebase Realtime Database reference builder.
class RefBuilder {
  final js.RefBuilder _inner;

  RefBuilder._(this._inner);

  /// Event handler that fires every time new data is created in Firebase
  /// Realtime Database.
  ///
  /// Optional [serializer], if provided, is used to deserialize value
  /// in to a Dart object.
  js.CloudFunction onCreate<T>(FutureOr<Null> handler(DatabaseEvent<T> event),
      [Serializer<T> serializer]) {
    dynamic wrapper(js.Event event) {
      return _handleEvent<T>(event, handler, serializer);
    }

    return _inner.onWrite(allowInterop(wrapper));
  }

  /// Event handler that fires every time data is deleted from Firebase
  /// Realtime Database.
  ///
  /// Optional [serializer], if provided, is used to deserialize value
  /// in to a Dart object.
  js.CloudFunction onDelete<T>(FutureOr<Null> handler(DatabaseEvent<T> event),
      [Serializer<T> serializer]) {
    dynamic wrapper(js.Event event) {
      return _handleEvent<T>(event, handler, serializer);
    }

    return _inner.onWrite(allowInterop(wrapper));
  }

  /// Event handler that fires every time data is updated in Firebase Realtime
  /// Database.
  ///
  /// Optional [serializer], if provided, is used to deserialize value
  /// in to a Dart object.
  js.CloudFunction onUpdate<T>(FutureOr<Null> handler(DatabaseEvent<T> event),
      [Serializer<T> serializer]) {
    dynamic wrapper(js.Event event) {
      return _handleEvent<T>(event, handler, serializer);
    }

    return _inner.onWrite(allowInterop(wrapper));
  }

  /// Event handler that fires every time a Firebase Realtime Database write of
  /// any kind (creation, update, or delete) occurs.
  ///
  /// Optional [serializer], if provided, is used to deserialize value
  /// in to a Dart object.
  js.CloudFunction onWrite<T>(FutureOr<Null> handler(DatabaseEvent<T> event),
      [Serializer<T> serializer]) {
    dynamic wrapper(js.Event event) {
      return _handleEvent<T>(event, handler, serializer);
    }

    return _inner.onWrite(allowInterop(wrapper));
  }

  dynamic _handleEvent<T>(
      js.Event event, FutureOr<Null> handler(DatabaseEvent<T> event),
      [Serializer<T> serializer]) {
    var dartEvent = new DatabaseEvent<T>(
      data: new DeltaSnapshot<T>(event.data, serializer),
      eventId: event.eventId,
      eventType: event.eventType,
      params: dartify(event.params),
      resource: event.resource,
      timestamp: DateTime.parse(event.timestamp),
    );
    var result = handler(dartEvent);
    if (result is Future) {
      return futureToJsPromise(result);
    }
    return null;
  }
}

/// Represents generic [Event] triggered by a Firebase service.
class Event<T> {
  /// Data returned for the event.
  ///
  /// The nature of the data depends on the [eventType].
  final T data;

  /// Unique identifier of this event.
  final String eventId;

  /// Type of this event.
  final String eventType;

  /// Values of the wildcards in the path parameter provided to the
  /// [Database.ref] method for a Realtime Database trigger.
  final Map<String, String> params;

  /// The resource that emitted the event.
  final String resource;

  /// Timestamp for this event.
  final DateTime timestamp;

  Event({
    this.data,
    this.eventId,
    this.eventType,
    this.params,
    this.resource,
    this.timestamp,
  });
}

/// An [Event] triggered by Firebase Realtime Database.
class DatabaseEvent<T> extends Event<DeltaSnapshot<T>> {
  DatabaseEvent({
    DeltaSnapshot data,
    String eventId,
    String eventType,
    Map<String, String> params,
    String resource,
    DateTime timestamp,
  })
      : super(
          data: data,
          eventId: eventId,
          eventType: eventType,
          params: params,
          resource: resource,
          timestamp: timestamp,
        );
}

/// Represents a Firebase Realtime Database delta snapshot.
class DeltaSnapshot<T> extends DataSnapshot<T> {
  DeltaSnapshot(js.DeltaSnapshot nativeInstance, [Serializer<T> serializer])
      : super(nativeInstance, serializer);

  js.DeltaSnapshot get nativeInstance => super.nativeInstance;

  /// Returns a [Reference] to the Database location where the triggering write
  /// occurred. Similar to [ref], but with full read and write access instead of
  /// end-user access.
  Reference get adminRef =>
      _adminRef ??= new Reference(nativeInstance.adminRef);
  Reference _adminRef;

  /// Tests whether data in the path has changed as a result of the triggered
  /// write.
  bool changed() => nativeInstance.changed();

  @override
  DeltaSnapshot<S> child<S>(String path, [Serializer<S> serializer]) =>
      super.child(path, serializer);

  /// Gets the current [DeltaSnapshot] after the triggering write event has
  /// occurred.
  DeltaSnapshot<T> get current =>
      new DeltaSnapshot<T>(nativeInstance.current, serializer);

  /// Gets the previous state of the [DeltaSnapshot], from before the
  /// triggering write event.
  DeltaSnapshot<T> get previous =>
      new DeltaSnapshot<T>(nativeInstance.previous, serializer);
}
