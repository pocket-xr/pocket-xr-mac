// Pocket XR for Mac as a streaming host: the two pieces of moonlight-common-c's native code the host side needs, so
// host and client speak exactly the same thing (as Sunshine builds them for its server): the control stream's ENet
// server (moonlight-common-c's ENet fork) and Reed-Solomon error correction (nanors). GPLv3; ENet and nanors are MIT
// (their LICENSE files are beside their sources). All ENet calls for one host must come from one thread.
#ifndef CHOSTNET_H
#define CHOSTNET_H

// An ENet server on UDP [port], all IPv4 addresses; null on failure.
void *PxrHostEnetStart(int port, int maxPeers);
void PxrHostEnetStop(void *host);
// Waits up to [timeoutMs] for one event: 0 none, 1 connect, 2 disconnect, 3 receive, -1 error. For receive, up to [cap]
// bytes go to [buf] and [len] is the packet's full length.
int PxrHostEnetService(void *host, int timeoutMs, void **peer, unsigned int *connectData, unsigned char *buf, int cap, int *len);
// A reliable packet on channel 0, flushed. 0 on success.
int PxrHostEnetSend(void *host, void *peer, const unsigned char *data, int len);
void PxrHostEnetDisconnect(void *peer);
// Video: parity for [dataShards] + [parityShards] shards of [blockSize] bytes laid out one after another (data first),
// written in place. 0 on success.
int PxrHostFecEncode(unsigned char *shards, int dataShards, int parityShards, int blockSize);
// Audio: 4 data + 2 parity shards with GameStream's own parity matrix. 0 on success.
int PxrHostAudioFecEncode(unsigned char *shards, int blockSize);

#endif
