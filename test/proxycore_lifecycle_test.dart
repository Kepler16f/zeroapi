import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/proxycore.dart';
import 'package:zeroapi/gateway/proxypool.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bundledKernel = File(
    '${Directory.current.path}${Platform.pathSeparator}'
    'vendor${Platform.pathSeparator}proxy-core${Platform.pathSeparator}'
    'mihomo.exe',
  );
  group(
    'ProxyCore real mihomo lifecycle',
    () {
      late Directory dataDir;
      late ProxyCore core;
      late ServerSocket dummy;

      setUp(() async {
        dataDir = await Directory.systemTemp.createTemp('proxycore-lifecycle-');
        dummy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        dummy.listen((socket) => socket.destroy());
        core = ProxyCore.testing(
          coreDir: bundledKernel.parent,
          dataDir: Directory(
            '${dataDir.path}${Platform.pathSeparator}core-data',
          ),
        );
      });

      tearDown(() async {
        await core.stop();
        await dummy.close();
        try {
          await dataDir.delete(recursive: true);
        } on FileSystemException {
          // Windows may release the process log/config handles just after exit.
        }
      });

      ProxyPool pool(String password) => ProxyPool(
        groups: [
          ProxyGroup(
            name: 'lifecycle',
            nodes: [
              ProxyNode(
                id: 'lifecycle-node',
                name: 'local-dummy',
                type: 'ss',
                host: InternetAddress.loopbackIPv4.address,
                port: dummy.port,
                password: password,
                extras: const {'cipher': 'aes-128-gcm'},
              ),
            ],
          ),
        ],
      );

      test('concurrent and repeated sync reuse one live listener', () async {
        final p = pool('first-secret');
        await Future.wait([core.sync(p), core.sync(p)]);
        expect(core.running, isTrue);
        expect(p.corePorts, hasLength(1));
        final firstPort = p.corePorts['lifecycle-node'];
        expect(firstPort, isNotNull);

        await core.sync(p);
        expect(core.running, isTrue);
        expect(core.ports['lifecycle-node'], firstPort);
        expect(p.corePorts['lifecycle-node'], firstPort);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test(
        'changed config restarts mihomo while preserving its listener port',
        () async {
          final p = pool('first-secret');
          await core.sync(p);
          final firstPort = core.ports['lifecycle-node'];
          expect(firstPort, isNotNull);

          final changed = pool('second-secret');
          await core.sync(changed);
          expect(core.running, isTrue);
          expect(core.ports['lifecycle-node'], firstPort);
          expect(changed.corePorts['lifecycle-node'], firstPort);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test('unexpected kernel exit is repaired by the next sync', () async {
        final p = pool('first-secret');
        await core.sync(p);
        final oldPort = core.ports['lifecycle-node'];
        expect(oldPort, isNotNull);

        await core.killForTesting();
        await core.sync(p);

        expect(core.running, isTrue);
        expect(core.ports, hasLength(1));
        expect(p.corePorts['lifecycle-node'], core.ports['lifecycle-node']);
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          core.ports['lifecycle-node']!,
          timeout: const Duration(seconds: 2),
        );
        socket.destroy();
      }, timeout: const Timeout(Duration(minutes: 2)));
    },
    skip: Platform.isWindows && bundledKernel.existsSync()
        ? false
        : 'requires the bundled Windows mihomo executable',
  );
}
