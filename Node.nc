/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"
#include "includes/DVRTable.h"
//  Tried using this am types header to add a flood address but not sure if it didn't work cause it wasn't compiling due code errors
//#include "includes/am_types.h"

module Node {

        //  Wiring from .nc File
        uses interface Boot;

        uses interface SplitControl as AMControl;
        uses interface Receive;

        uses interface SimpleSend as Sender;

        uses interface CommandHandler;

        uses interface List <pack> as PackLogs;

        uses interface Hashmap <uint16_t> as NeighborList;

        uses interface Random as Random;

        uses interface Timer<TMilli> as Timer;
}

implementation {

        pack sendPackage;
        uint16_t nodeSeq = 0;
        uint16_t discoveryCount = 0;
        //DVRTable table;

        //  Here we can lis all the neighbors for this mote
        //  We getting an error with neighbors

        //  Prototypes
        void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
        void logPacket(pack* payload);
        bool hasSeen(pack* payload);
        void addNeighbor(pack* Neighbor);
        void relayToNeighbors();
        bool destIsNeighbor(pack* recievedMsg);
        void scanNeighbors();
        void clearNeighbors();

        //  Node boot time calls
        event void Boot.booted(){
                uint32_t t0, dt;
                //  Booting/Starting our lowest networking layer exposed in TinyOS which is also called active messages (AM)
                call AMControl.start();

                // t0 Timer start time, dt Timer interval time
                t0 = 500 + call Random.rand32() % 2000;
                dt = 25000 + (call Random.rand32() % 10000);
                call Timer.startPeriodicAt(t0, dt);

                dbg(GENERAL_CHANNEL, "\tBooted\n");
        }

        //  This function is ran after t0 Milliseconds the node is alive, and fires every dt seconds.
        event void Timer.fired() {
                // We might wanna remove this since the timer fires fro every 25 seconds to 35 Seconds
                ++discoveryCount;
                if((discoveryCount % 3) == 0)
                        clearNeighbors();
                scanNeighbors();
                //dbg(GENERAL_CHANNEL, "\tTimer Fired!\n");
        }

        //  Make sure all the Radios are turned on
        event void AMControl.startDone(error_t err){
                if(err == SUCCESS)
                        dbg(GENERAL_CHANNEL, "\tRadio On\n");
                else
                        call AMControl.start();
        }

        event void AMControl.stopDone(error_t err){
        }

        //  Handles all the Packs we are receiving.
        event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
                pack* recievedMsg;
                recievedMsg = (pack *)payload;

                if (len == sizeof(pack)) {

                        //  Dead Packet: Timed out
                        if (recievedMsg->TTL == 0) {
                                //dbg(GENERAL_CHANNEL, "\tPackage(%d,%d) Dead of old age\n", recievedMsg->src, recievedMsg->dest);
                                return msg;
                        }

                        //  Old Packet: Has been seen
                        else if (hasSeen(recievedMsg)) {
                                //dbg(GENERAL_CHANNEL, "\tPackage(%d,%d) Seen Before\n", recievedMsg->src, recievedMsg->dest);
                                return msg;
                        }

                        //  Ping to me
                        if (recievedMsg->protocol == PROTOCOL_PING && recievedMsg->dest == TOS_NODE_ID) {
                                dbg(FLOODING_CHANNEL, "\tPackage(%d,%d) -------------------------------------------------->>>>Ping: %s\n", recievedMsg->src, recievedMsg->dest,  recievedMsg->payload);
                                logPacket(&sendPackage);

                                // Sending Ping Reply
                                nodeSeq++;
                                makePack(&sendPackage, recievedMsg->dest, recievedMsg->src, MAX_TTL, PROTOCOL_PINGREPLY, nodeSeq, (uint8_t*)recievedMsg->payload, len);
                                logPacket(&sendPackage);
                                call Sender.send(sendPackage, AM_BROADCAST_ADDR);

                                //signal CommandHandler.printNeighbors();
                                return msg;
                        }

                        //  Ping Reply to me
                        else if (recievedMsg->protocol == PROTOCOL_PINGREPLY && recievedMsg->dest == TOS_NODE_ID) {
                                dbg(FLOODING_CHANNEL, "\tPackage(%d,%d) -------------------------------------------------->>>>Ping Reply: %s\n", recievedMsg->src, recievedMsg->dest, recievedMsg->payload);
                                logPacket(&sendPackage);
                                return msg;
                        }

                        //  Neighbor Discovery: Timer
                        else if (recievedMsg->protocol == PROTOCOL_PING && recievedMsg->dest == AM_BROADCAST_ADDR && recievedMsg->TTL == 1) {
                                //dbg(GENERAL_CHANNEL, "\tNeighbor Discovery Ping Recieved\n");
                                // Log as neighbor
                                addNeighbor(recievedMsg);
                                return msg;
                        }

                        // Relaying Packet: Not for us
                        else if (recievedMsg->dest != TOS_NODE_ID && recievedMsg->dest != AM_BROADCAST_ADDR) {
                                //dbg(GENERAL_CHANNEL, "\tPackage(%d,%d) Relay\n", recievedMsg->src, recievedMsg->dest);

                                // Forward and logging package
                                recievedMsg->TTL--;
                                makePack(&sendPackage, recievedMsg->src, recievedMsg->dest, recievedMsg->TTL, recievedMsg->protocol, recievedMsg->seq, (uint8_t*)recievedMsg->payload, len);
                                logPacket(&sendPackage);

                                /**********FOR LATER: Reduce Spamming the network**************
                                 * Need to use node-specific neighbors for destination
                                 * rather than AM_BROADCAST_ADDR after we implement
                                 * neighbor discovery
                                 */
                                if (destIsNeighbor(recievedMsg))
                                        call Sender.send(sendPackage, recievedMsg->dest);
                                else
                                        relayToNeighbors();
                                return msg;
                        }

                        // If Packet get here we have not expected it and it will fail
                        dbg(GENERAL_CHANNEL, "\tUnknown Packet Type %d\n", len);
                        return msg;
                }// End of Currupt if statement

                dbg(GENERAL_CHANNEL, "\tPackage(%d,%d) Currrupted", recievedMsg->src, recievedMsg->dest);
                return msg;
        }

        //  This is how we send a Ping to one another
        event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
                nodeSeq++;

                dbg(GENERAL_CHANNEL, "\tPackage(%d,%d) Ping Sent\n", TOS_NODE_ID, destination);
                makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, nodeSeq, payload, PACKET_MAX_PAYLOAD_SIZE);
                //logPack(&sendPackage);
                logPacket(&sendPackage);
                call Sender.send(sendPackage, AM_BROADCAST_ADDR);
        }

        //  This are functions we are going to be implementing in the future.
        event void CommandHandler.printNeighbors(){
                int i;
                uint16_t *key;
                if(call NeighborList.size() !=  0) {
                        *key = (uint16_t) call NeighborList.getKeys();
                        for(i = 0; i < (call NeighborList.size()); i++) {
                                dbg(NEIGHBOR_CHANNEL, "%d -> %d\n", TOS_NODE_ID, *key);
                                key++;
                        }
                } else {
                        dbg(NEIGHBOR_CHANNEL, "\tNeighbors List Empty\n");
                }
        }

        event void CommandHandler.printRouteTable(){
        }

        event void CommandHandler.printLinkState(){
        }

        event void CommandHandler.printDistanceVector(){
        }

        event void CommandHandler.setTestServer(){
        }

        event void CommandHandler.setTestClient(){
        }

        event void CommandHandler.setAppServer(){
        }

        event void CommandHandler.setAppClient(){
        }

        void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
                Package->src = src;
                Package->dest = dest;
                Package->TTL = TTL;
                Package->seq = seq;
                Package->protocol = protocol;
                memcpy(Package->payload, payload, length);
        }

        //  Logging Packets: Knowledge of seen Packets
        void logPacket(pack* payload) {

                uint16_t src = payload->src;
                uint16_t seq = payload->seq;
                pack loggedPack;

                //if packet log isnt empty and contains the src key
                if(call PackLogs.size() == PackLogs->HASH_MAX_SIZE) {
                        //remove old key value pair and insert new one
                        call PackLogs.popfront();
                }
                //logPack(payload);
                makePack(&loggedPack, payload->src, payload->dest, payload->TTL, payload->protocol, payload->seq, (uint8_t*) payload->payload, sizeof(pack));
                call PackLogs.pushback(loggedPack);

                /* if (payload->protocol == PROTOCOL_PING) {
                   dbg(FLOODING_CHANNEL, "\tPackage(%d,%d)---Ping: Updated Seen Packs List\n", payload->src, payload->dest);
                   } else if (payload->protocol == PROTOCOL_PINGREPLY) {
                   dbg(FLOODING_CHANNEL, "\tPackage(%d,%d)~~~Ping Reply: Updated Seen Packs List\n", payload->src, payload->dest);
                   } else {

                   } */
        }

        bool hasSeen(pack* payload) {
                pack stored;
                int i;

                //dbg(FLOODING_CHANNEL, "\tPackage(%d,%d) S_Checking Message:%s\n", payload->src, payload->dest, payload->payload);
                if(!call PackLogs.isEmpty()) {
                        for (i = 0; i < call PackLogs.size(); i++) {
                                stored = call PackLogs.get(i);
                                if (stored.src == payload->src && stored.seq <= payload->seq) {
                                        return 1;
                                }
                        }
                }
                return 0;
        }

        void addNeighbor(pack* Neighbor) {
                int size = call NeighborList.size();

                if (!hasSeen(Neighbor)) {
                        call NeighborList.insert(Neighbor->src, table->MAX_AGE);
                        //dbg(NEIGHBOR_CHANNEL, "\tNeighbors Discovered: %d\n", Neighbor->src);
                }
        }

        //  sends message to all known neighbors in neighbor list; if list is empty, forwards to everyone within range using AM_BROADCAST_ADDR.
        void relayToNeighbors() {
                int i, size;
                uint16_t *key;
                dbg(NEIGHBOR_CHANNEL, "\tTrynna Forward To Neighbors\n");

                if(!call NeighborList.isEmpty()) {
                        size = call NeighborList.size();
                        *key = call NeighborList.getKeys();
                        for(i = 0; i < size; i++) {
                                /**********FOR LATER************
                                 * Figure out how to exclude original sender
                                 */

                                call Sender.send(sendPackage, *key);
                                key++;
                        }
                } else {
                        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                }
        }

        bool destIsNeighbor(pack* recievedMsg) {
                int i, size, loggedNeighbor;
                int destination = recievedMsg->dest;
                uint16_t *key;

                dbg(NEIGHBOR_CHANNEL, "\tTrynna Forward To DESTINATION\n");

                if(!call NeighborList.isEmpty()) {
                        size = call NeighborList.size();
                        *key = call NeighborList.getKeys();
                        for(i = 0; i < size; i++) {
                                loggedNeighbor = *key;
                                key++;
                                if( loggedNeighbor == destination)
                                        return 1;
                        }
                }
                return 0;
        }

        void scanNeighbors() {
                nodeSeq++;
                makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 1, PROTOCOL_PING, nodeSeq, "Looking-4-Neighbors", PACKET_MAX_PAYLOAD_SIZE);
                call Sender.send(sendPackage, AM_BROADCAST_ADDR);
        }

//why packlogs and not neighborlist
        void clearNeighbors() {
                int size;
                size = call NeighborList.size();
                while (size > 1) {
                        call PackLogs.popfront();
                        size--;
                }
        }


}
