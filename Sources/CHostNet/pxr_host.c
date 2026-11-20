// Pocket XR for Mac as a streaming host: ENet server and Reed-Solomon, as Pocket XR for Windows' pxr_host.c (GPLv3).
#include <string.h>
#include <stdlib.h>

#include <enet/enet.h>
#include "rs.h"
#include "CHostNet.h"

static int enetReady, rsReady;

void *PxrHostEnetStart(int port, int maxPeers) {
    if (!enetReady) {
        if (enet_initialize() != 0) return NULL;
        enetReady = 1;
    }
    ENetAddress addr;
    memset(&addr, 0, sizeof(addr));
    if (enet_address_set_host(&addr, "0.0.0.0") != 0) return NULL;
    enet_address_set_port(&addr, (enet_uint16)port);
    return enet_host_create(AF_INET, &addr, (size_t)maxPeers, 0, 0, 0);
}

void PxrHostEnetStop(void *host) {
    if (host) enet_host_destroy((ENetHost *)host);
}

int PxrHostEnetService(void *host, int timeoutMs, void **peer, unsigned int *connectData, unsigned char *buf, int cap, int *len) {
    ENetEvent ev;
    int r = enet_host_service((ENetHost *)host, &ev, (enet_uint32)timeoutMs);
    if (r <= 0) return r;
    *peer = ev.peer;
    *connectData = ev.data;
    switch (ev.type) {
        case ENET_EVENT_TYPE_CONNECT: return 1;
        case ENET_EVENT_TYPE_DISCONNECT: return 2;
        case ENET_EVENT_TYPE_RECEIVE: {
            int n = (int)ev.packet->dataLength;
            *len = n;
            memcpy(buf, ev.packet->data, (size_t)(n < cap ? n : cap));
            enet_packet_destroy(ev.packet);
            return 3;
        }
        default: return 0;
    }
}

int PxrHostEnetSend(void *host, void *peer, const unsigned char *data, int len) {
    ENetPacket *p = enet_packet_create(data, (size_t)len, ENET_PACKET_FLAG_RELIABLE);
    if (p == NULL) return -1;
    if (enet_peer_send((ENetPeer *)peer, 0, p) != 0) {
        enet_packet_destroy(p);
        return -1;
    }
    enet_host_flush((ENetHost *)host);
    return 0;
}

void PxrHostEnetDisconnect(void *peer) {
    enet_peer_disconnect_now((ENetPeer *)peer, 0);
}

int PxrHostAudioFecEncode(unsigned char *shards, int blockSize) {
    if (!rsReady) {
        reed_solomon_init();
        rsReady = 1;
    }
    static const unsigned char parity[8] = { 0x77, 0x40, 0x38, 0x0e, 0xc7, 0xa7, 0x0d, 0x6c };
    uint8_t *p[6];
    for (int i = 0; i < 6; i++) p[i] = shards + (size_t)i * (size_t)blockSize;
    reed_solomon *rs = reed_solomon_new(4, 2);
    if (rs == NULL) return -1;
    memcpy(rs->p, parity, sizeof(parity));
    int r = reed_solomon_encode(rs, p, 6, blockSize);
    reed_solomon_release(rs);
    return r;
}

int PxrHostFecEncode(unsigned char *shards, int dataShards, int parityShards, int blockSize) {
    if (!rsReady) {
        reed_solomon_init();
        rsReady = 1;
    }
    int total = dataShards + parityShards;
    uint8_t **p = (uint8_t **)malloc(sizeof(uint8_t *) * (size_t)total);
    if (p == NULL) return -1;
    for (int i = 0; i < total; i++) p[i] = shards + (size_t)i * (size_t)blockSize;
    reed_solomon *rs = reed_solomon_new(dataShards, parityShards);
    if (rs == NULL) {
        free(p);
        return -1;
    }
    int r = reed_solomon_encode(rs, p, total, blockSize);
    reed_solomon_release(rs);
    free(p);
    return r;
}
