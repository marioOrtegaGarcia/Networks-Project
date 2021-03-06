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
#include "includes/socket.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

//#include "includes/DVRTable.h"
//  Tried using this am types header to add a flood address but not sure if it didn't work cause it wasn't compiling due code errors
//#include "includes/am_types.h"

module Node {

        //  Wiring from .nc File
        uses interface Boot;

        uses interface SplitControl as AMControl;
        uses interface Receive;

        uses interface SimpleSend as Sender;

        uses interface CommandHandler;

        uses interface Transport;

        uses interface List <pack> as PackLogs;
	uses interface List <socket_t> as Socks;
	uses interface List <uint8_t> as stringInts;

        //uses interface List <uint16_t> as NeighborList;
        //uses interface List <NeighborNode> as NeighborList;

        uses interface Random as Random;

        uses interface Timer<TMilli> as Timer;

        uses interface Timer<TMilli> as TableUpdateTimer;

        uses interface Timer<TMilli> as ListenTimer;

        uses interface Timer<TMilli> as WriteTimer;

	uses interface Timer<TMilli> as ChatTimer;

	uses interface Timer<TMilli> as TimedOut;

        //uses interface DVRTableC <uint8_t> as Table;
}

implementation {

        pack sendPackage;
        uint8_t poolSize =  9;
        uint16_t nodeSeq = 0;
        uint8_t MAX_HOP = 18;
        bool fired = FALSE;
        bool initialized = FALSE;
        uint8_t numroutes = 0;
        uint8_t NeighborListSize = 19;
        uint8_t MAX_NEIGHBOR_TTL = 20;
        uint8_t NeighborList[19];
        uint8_t routing[255][3];
	socket_t fd;
	uint8_t transfer = 0;

        //  Prototypes
        void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
        void logPacket(pack* payload);
        bool hasSeen(pack* payload);
        void addNeighbor(uint8_t Neighbor);
        void reduceNeighborsTTL();
        void relayToNeighbors(pack* recievedMsg);
        bool destIsNeighbor(pack* recievedMsg);
        void scanNeighbors();
        //DV Table Functions
        void initialize();
        void insert(uint8_t dest, uint8_t cost, uint8_t nextHop);
        void sendTableToNeighbors();

        bool mergeRoute(uint8_t* newRoute, uint8_t src);
        void splitHorizon(uint8_t nextHop);
        uint8_t findNextHop(uint8_t dest);

	error_t pushComm2List(char commandString[], uint8_t size) {
		int i = 0;

		/* dbg(GENERAL_CHANNEL, "----------> HERE\n"); */
		for (i = 0; i < size-1; i++) {
			/* dbg(GENERAL_CHANNEL, "Char(%c) -> Int(%i)\n", commandString[i], (uint8_t)commandString[i]); */
			call stringInts.pushback((uint8_t)commandString[i]);
		}

		if(call stringInts.size() == size-1) {
			dbg(GENERAL_CHANNEL, "Pushed All to List\n");
			return SUCCESS;
		}

		dbg(GENERAL_CHANNEL, "Failed to push all to list");
		return FAIL;
	}

        //  Node boot time calls
        event void Boot.booted(){
                uint32_t t0, dt;
                //  Booting/Starting our lowest networking layer exposed in TinyOS which is also called active messages (AM)
                call AMControl.start();

                // t0 Timer start time, dt Timer interval time
                t0 = 500 + call Random.rand32() % 1000;
                dt = 25000 + (call Random.rand32() % 10000);
                call Timer.startPeriodicAt(t0, dt);

                dbg(GENERAL_CHANNEL, "\tBooted\n");
        }

	/*
████████ ██ ███    ███ ███████ ██████  ███████
   ██    ██ ████  ████ ██      ██   ██ ██
   ██    ██ ██ ████ ██ █████   ██████  ███████
   ██    ██ ██  ██  ██ ██      ██   ██      ██
   ██    ██ ██      ██ ███████ ██   ██ ███████
*/
        //  This function is ran after t0 Milliseconds the node is alive, and fires every dt seconds.
        event void Timer.fired() {
                uint32_t t0, dt;
                scanNeighbors();

                t0 = 20000 + call Random.rand32() % 1000;
                dt = 25000 + (call Random.rand32() % 10000);
                if(!fired){
                     call TableUpdateTimer.startPeriodicAt(t0, dt);
                     fired = TRUE;
                }

                //dbg(GENERAL_CHANNEL, "\tTimer Fired!\n");
        }

        event void TableUpdateTimer.fired() {
             if(initialized == FALSE) {
                     initialize();
                     initialized = TRUE;
                  //signal CommandHandler.printNeighbors();
             } else {
                //dbg (GENERAL_CHANNEL, "\tNode %d is Sharing his table with Neighbors\n", TOS_NODE_ID);
                sendTableToNeighbors();
             }
        }

        /*
        int newFd = accept();
        if newFd not NULL_SOCKET
        add to list of accepted sockets
        for all sockets added
        read data and print
        */

	event void ListenTimer.fired() {
		int i, len;
		socket_store_t sock;
		//dbg(GENERAL_CHANNEL, "\tListenTimer Fired\n");
		dbg(GENERAL_CHANNEL, "ListenTimer.fired() {\n");


		fd = call Transport.accept(fd);

		if(fd != (socket_t)NULL)  {
			//TODO insert new sock
			if (call Socks.size() < 10) {
				dbg(GENERAL_CHANNEL, "\t-- Succesfully saved new fd: %d\n", fd);
				call Socks.pushback(fd);
				} else {
					dbg(GENERAL_CHANNEL, "\t-- Socks is full\n");
				}

				sock = call Transport.getSocket(fd);

				//read and print all data
				dbg(GENERAL_CHANNEL,"\t-- Reading from buffer\n");
				len = call Transport.read(fd, (uint8_t*)sock.rcvdBuff, SOCKET_BUFFER_SIZE);
				dbg(GENERAL_CHANNEL,"\t-- len: %d\n", len);
		} else {
			dbg(GENERAL_CHANNEL, "\t-- fd is NULL\n");
		}

		/* = call sockets.get(keys);

		int newFd = call Transport.accept(); */
		/* if((uint16_t)newFd != (uint16_t)NULL){
			add to list of accepted sockets
		}
		for all sockets added
		read data and print */
	}

	event void WriteTimer.fired() {
		/*
		//data is from 0 to [transfer]
		subtract the amount of data you were able to write(fd, buffer, buffer len)
		*/
		socket_store_t sock;


		dbg(GENERAL_CHANNEL, "\t WriteTimer.fired() ->\n");

		if (call Transport.isValidSocket(fd)) {
			dbg(GENERAL_CHANNEL, "\t\t\t    -- Socket is valid: True\n");
			sock = call Transport.getSocket(fd);
		} else {
			dbg(GENERAL_CHANNEL, "\t\t\t    -- Socket is valid: False\n");
		}
		//if all data in buffer has been writtin or buffer is empty
		if(sock.lastWritten == SOCKET_BUFFER_SIZE || sock.lastWritten == 0) {
			//Make  new data
			dbg(GENERAL_CHANNEL, "\t\t\t    -- Begining to  make data, sending %u bytes\n", transfer);
			//TODO use read/write to implement fixed sliding window
			//in the meantime, here is stop & wait
			call Transport.stopWait(sock, transfer, nodeSeq);
			nodeSeq++;
		} else {
			dbg(GENERAL_CHANNEL, "WriteTimer.fired() -- fd could not befound\n");
		}

	}

	event void ChatTimer.fired() {
		socket_store_t sock;
		dbg(GENERAL_CHANNEL,  "Chat Write Timer Fired\n");

		if (call Transport.isValidSocket(fd)) {
			sock = call Transport.getSocket(fd);
			if (sock.lastWritten == SOCKET_BUFFER_SIZE || sock.lastWritten == 0) {
				while (call stringInts.size() !=  0) {
					call Transport.passChar(call stringInts.popfront());
				}
				call Transport.charSend(sock, nodeSeq, 0);
			}
		}
	}

	event void TimedOut.fired(){
		//resend buffered data, with  same seq number.


		dbg(GENERAL_CHANNEL, "TimedOut.fired() -- no ACK  received \n");

	}

	//  Make sure all the Radios are turned on
	event void AMControl.startDone(error_t err)  {
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
                uint8_t nHop;
                bool alteredRoute = FALSE;
                recievedMsg = (pack *)payload;

                if (len == sizeof(pack)) {
                        //  Dead Packet: Timed out
                        if (recievedMsg->TTL == 0) {
                                dbg(GENERAL_CHANNEL, "\tPackage(%d,%d) Dead of old age\n", recievedMsg->src, recievedMsg->dest);
                                return msg;
                        }

                        //  Old Packet: Has been seen
                        else if (hasSeen(recievedMsg)) {
                                //dbg(GENERAL_CHANNEL, "\tPackage(%d,%d) Seen Before\n", recievedMsg->src, recievedMsg->dest);
                                return msg;
                        }

                        //  Ping to me
                        if (recievedMsg->protocol == PROTOCOL_PING && recievedMsg->dest == TOS_NODE_ID) {
                                dbg(FLOODING_CHANNEL, "\tPackage(%d,%d) Ping Recieved Seq(%d): %s\n", recievedMsg->src, recievedMsg->dest,  recievedMsg->seq, recievedMsg->payload);
                                logPacket(&sendPackage);

                                // Sending Ping Reply
                                nodeSeq++;
                                makePack(&sendPackage, recievedMsg->dest, recievedMsg->src, MAX_TTL, PROTOCOL_PINGREPLY, nodeSeq, (uint8_t*)recievedMsg->payload, len);
                                logPacket(&sendPackage);
                                nHop = findNextHop(recievedMsg->src);
                                call Sender.send(sendPackage, nHop);

                                //signal CommandHandler.printNeighbors();
                                //signal CommandHandler.printRouteTable();
                                return msg;
                        }

                        //  Ping Reply to me
                        else if (recievedMsg->protocol == PROTOCOL_PINGREPLY && recievedMsg->dest == TOS_NODE_ID) {
                                dbg(FLOODING_CHANNEL, "\tPackage(%d,%d) Ping Reply Recieved: %s\n", recievedMsg->src, recievedMsg->dest, recievedMsg->payload);
                                logPacket(&sendPackage);
                                return msg;
                        }

                        //  Neighbor Discovery: Timer
                        else if (recievedMsg->protocol == PROTOCOL_PING && recievedMsg->dest == AM_BROADCAST_ADDR) {
                                //dbg(GENERAL_CHANNEL, "\tNeighbor Discovery Ping Recieved\n");
                                // Log as neighbor
                                //dbg(GENERAL_CHANNEL, "Neighbor Discovery packet SRC: %d\n", recievedMsg->src);
                                addNeighbor(recievedMsg->src);
                                logPacket(recievedMsg);
                                return msg;
                        }

                        // Receiving DV Table
                        else if(recievedMsg->dest == TOS_NODE_ID && recievedMsg->protocol == PROTOCOL_DV) {
                             /* dbg(GENERAL_CHANNEL, "CALLING MERGERROUTE!!\n"); */
                             alteredRoute = mergeRoute((uint8_t*)recievedMsg->payload, (uint8_t)recievedMsg->src);
                             //signal CommandHandler.printRouteTable();
                             if(alteredRoute){
                                  sendTableToNeighbors();
                             }
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
                                //signal CommandHandler.printNeighbors();
                                relayToNeighbors(&sendPackage);
                                return msg;
                        }
			else if (recievedMsg->protocol == PROTOCOL_TCP && recievedMsg->dest == TOS_NODE_ID) {
				dbg(GENERAL_CHANNEL, "Recieved a TCP Pack\n");
				logPacket(&sendPackage);
				call Transport.receive(recievedMsg);

				return msg;
			} else if (recievedMsg->protocol == PROTOCOL_TCP && recievedMsg->dest != TOS_NODE_ID) {
				recievedMsg->TTL--;
				makePack(&sendPackage, recievedMsg->src, recievedMsg->dest, recievedMsg->TTL, recievedMsg->protocol, recievedMsg->seq, (uint8_t*)recievedMsg->payload, len);
                                logPacket(&sendPackage);
				relayToNeighbors(&sendPackage);
				return msg;
			}

                        // If Packet get here we have not expected it and it will fail
                        dbg(GENERAL_CHANNEL, "\tUnknown Packet Type with %d\n", len);
                        return msg;
                }// End of Currupt if statement

                dbg(GENERAL_CHANNEL, "\tPackage(%d,%d) Currrupted", recievedMsg->src, recievedMsg->dest);
                return msg;
        }
        /*
        ██████  ██ ███    ██  ██████
        ██   ██ ██ ████   ██ ██
        ██████  ██ ██ ██  ██ ██   ███
        ██      ██ ██  ██ ██ ██    ██
        ██      ██ ██   ████  ██████
        */


        //  This is how we send a Ping to one another
	event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
		nodeSeq++;

		dbg(GENERAL_CHANNEL, "\tPackage(%d,%d) Ping Sent\n", TOS_NODE_ID, destination);
		/* PACKET_MAX_PAYLOAD_SIZE); */
		logPack(&sendPackage);
		logPacket(&sendPackage);
		if (!initialized) {
			call Sender.send(sendPackage, AM_BROADCAST_ADDR);
			} else {
				call Sender.send(sendPackage, findNextHop(destination));
			}

	}

        /*
██████  ██████  ██ ███    ██ ████████ ███████
██   ██ ██   ██ ██ ████   ██    ██    ██
██████  ██████  ██ ██ ██  ██    ██    ███████
██      ██   ██ ██ ██  ██ ██    ██         ██
██      ██   ██ ██ ██   ████    ██    ███████
*/

	// This are functions we are going to be implementing in the future.
	event void CommandHandler.printNeighbors() {
		int i, count = 0;

		dbg(NEIGHBOR_CHANNEL, "\t~~~~~~~Mote %d's Neighbors~~~~~~~\n", TOS_NODE_ID);
		for(i = 1; i < (NeighborListSize); i++) {
			if(NeighborList[i] > 0) {
				dbg(NEIGHBOR_CHANNEL, "\t\t   %d -> %d\n", TOS_NODE_ID, i);
				count++;
			}
		}
		if(count == 0)
		dbg(NEIGHBOR_CHANNEL, "Neighbor List is Empty\n");
	}

	event void CommandHandler.printRouteTable() {
		int i;
		dbg(GENERAL_CHANNEL, "\t~~~~~~~Mote %d's Routing Table~~~~~~~\n", TOS_NODE_ID);
		dbg(GENERAL_CHANNEL, "\tDest\tCost\tNext Hop:\n");
		for (i = 1; i <= poolSize; i++) {
			dbg(GENERAL_CHANNEL, "\t  %d \t  %d \t    %d \n", routing[i][0], routing[i][1], routing[i][2]);
		}
	}

        event void CommandHandler.printLinkState() {
        }

        event void CommandHandler.printDistanceVector() {
        }

        /*
        ████████  ██████ ██████
           ██    ██      ██   ██
           ██    ██      ██████
           ██    ██      ██
           ██     ██████ ██
        */



	event void CommandHandler.setTestServer(uint8_t port) {
		socket_addr_t socketAddr;
		dbg(GENERAL_CHANNEL, "CommandHandler.setTestServer(%d) -- Initializing Server\n", port);

		/* call Transport.passSeq(&nodeSeq); */

		// Creating our file descriptor
		fd = call Transport.socket();

		// Setting the port and address of our Server
		socketAddr.port = port;
		socketAddr.addr = TOS_NODE_ID;

		// Making sure we have a Successful bind
		if (call Transport.bind(fd, &socketAddr) == SUCCESS) {
			// Making sure were in the listening state
			call Transport.passNeighborsList(&NeighborList);
			if(call Transport.listen(fd) == SUCCESS) {
				// Calling our listen timer
				call ListenTimer.startOneShot(30000);
			}
		}
	}

	event void CommandHandler.setTestClient(uint16_t dest, uint8_t srcPort, uint8_t destPort, uint8_t num){

		int i;
		socket_store_t socket;
		socket_addr_t socketAddr, serverAddr;
		error_t check = FAIL;
		transfer = num;

		/* call Transport.passSeq(&nodeSeq); */
		dbg(GENERAL_CHANNEL, "CommandHandler.setTestClient()\n");

		// Creating our file descriptor
		fd = call Transport.socket();

		// Setting the port and address of our Client
		socketAddr.addr = TOS_NODE_ID;
		socketAddr.port = srcPort;

		if  (call Transport.bind(fd, &socketAddr) == SUCCESS) {
			//dbg(GENERAL_CHANNEL, "\t-- Bind Successful.\n");

			// Setting our destination address and port
			serverAddr.addr = dest;
			serverAddr.port = destPort;
			call Transport.passNeighborsList(&NeighborList);

			if (call Transport.connect(fd, &serverAddr) == SUCCESS)  {
				dbg(GENERAL_CHANNEL, "\t-- Connection Secure.\n");
				//send [max transfer size] data in packet
				//call WriteTimer.startOneShot(30000);
				call WriteTimer.startOneShot(60000);
			} else {
				dbg(GENERAL_CHANNEL, "\t-- Couldnt Connect\n");
			}
		} else {
			dbg(GENERAL_CHANNEL, "\t-- Get rekt son, Couldn't bind.\n");
		}
	}

	event void CommandHandler.setAppServer() {
		// This pretty much remakes this function but addapts itself to be able to send a Array of Chats to an array of Ints
		//signal CommandHandler.setTestServer(41);

		socket_addr_t socketAddr;
		uint8_t port = 41;

		dbg(GENERAL_CHANNEL, "Creating App Server at port: %d\n", port);
		fd = call Transport.socket();

		dbg(GENERAL_CHANNEL, "Generating socketAddr\n");
		socketAddr.port = port;
		socketAddr.addr = TOS_NODE_ID;

		dbg(GENERAL_CHANNEL, "Binding to the socket\n");
		if (call Transport.bind(fd, &socketAddr) == SUCCESS) {
			// Sharing the neighbors list
			call Transport.passNeighborsList(&NeighborList);
			if (call Transport.listen(fd) == SUCCESS) {

				dbg(GENERAL_CHANNEL, "One shot to be coded for concatenation of recieved command\n");
				// One shot maybe for concatenation of recieved command

			}
		}


		dbg(GENERAL_CHANNEL, "\tDEBUG\n");
        }
	//event void CommandHandler.setTestClient(uint16_t dest, uint8_t srcPort, uint8_t destPort, uint8_t num){
	event void CommandHandler.setAppClient(uint8_t port) {
		uint8_t i;
		socket_store_t socket;
		socket_addr_t socketAddr, serverAddr;
		error_t check = FAIL;
		char commandSent[] = "hello ascerpa 3\r\n";
		transfer = sizeof(commandSent)/ sizeof(char);

		/* for (i = 0; i < 18; i++) {
			dbg(GENERAL_CHANNEL, "\t%c\n", commandSent[i]);
		} */

		dbg(GENERAL_CHANNEL, "SETTING APP CLIENT FOR %d\n", TOS_NODE_ID);
		// Creating our file descriptor
		fd = call Transport.socket();

		// Setting the port and address of our Client
		socketAddr.addr = TOS_NODE_ID;
		socketAddr.port = port;

		if  (call Transport.bind(fd, &socketAddr) == SUCCESS) {
			// Setting our destination address and port for App Server
			serverAddr.addr = 1;
			serverAddr.port = 41;

			call Transport.passNeighborsList(&NeighborList);

			if (call Transport.connect(fd, &serverAddr) == SUCCESS)  {
				dbg(GENERAL_CHANNEL, "\t-- Connection Secure.\n");
				//send [max transfer size] data in packet
				//call WriteTimer.startOneShot(30000);
				//call WriteTimer.startOneShot(60000);
				dbg(GENERAL_CHANNEL, "Where we insert to  the array\n");

				dbg(GENERAL_CHANNEL, "Attempting to convert string\n");
				if(pushComm2List(commandSent, sizeof(commandSent)/sizeof(char)) == SUCCESS) {
					call ChatTimer.startOneShot(5000);
				}


			}
		}

        }
        event void CommandHandler.closeConnection(uint16_t dest, uint8_t srcPort, uint8_t  destPort, uint8_t num) {
                int i;
		/* socket_t fd; */
		socket_store_t socket;
		fd = call Transport.findSocket(srcPort, destPort, dest);


		call Transport.close(fd, nodeSeq++);
        }

        /*
██████   █████   ██████ ██   ██     ██   ██  █████  ███    ██ ██████  ██      ███████ ██      ██ ███    ██  ██████
██   ██ ██   ██ ██      ██  ██      ██   ██ ██   ██ ████   ██ ██   ██ ██      ██      ██      ██ ████   ██ ██
██████  ███████ ██      █████       ███████ ███████ ██ ██  ██ ██   ██ ██      █████   ██      ██ ██ ██  ██ ██   ███
██      ██   ██ ██      ██  ██      ██   ██ ██   ██ ██  ██ ██ ██   ██ ██      ██      ██      ██ ██  ██ ██ ██    ██
██      ██   ██  ██████ ██   ██     ██   ██ ██   ██ ██   ████ ██████  ███████ ███████ ███████ ██ ██   ████  ██████
*/



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
                if(call PackLogs.size() == 64) {
                        //remove old key value pair and insert new one
                        call PackLogs.popfront();
                }
                //logPack(payload);
                makePack(&loggedPack, payload->src, payload->dest, payload->TTL, payload->protocol, payload->seq, (uint8_t*) payload->payload, sizeof(pack));
                call PackLogs.pushback(loggedPack);

                if (payload->protocol == PROTOCOL_PING) {
                   //dbg(FLOODING_CHANNEL, "\tPackage(%d,%d)---Ping: Updated Seen Packs List\n", payload->src, payload->dest);
                   } else if (payload->protocol == PROTOCOL_PINGREPLY) {
                   //dbg(FLOODING_CHANNEL, "\tPackage(%d,%d)~~~Ping Reply: Updated Seen Packs List\n", payload->src, payload->dest);
                   } else {

                   }
        }

        bool hasSeen(pack* packet) {
                pack stored;
                int i, size;
                size = call PackLogs.size();
                //dbg(FLOODING_CHANNEL, "\t%i Packets in the list\n", size);
                //dbg(FLOODING_CHANNEL, "\tPackage(%d,%d) S_Checking Message:%s\n", payload->src, payload->dest, payload->payload);
                if(size > 0) {
                        //dbg(FLOODING_CHANNEL, "\tPackage(%d,%d) PackLogs not Empty:%s\n", payload->src, payload->dest, payload->payload);
                        for (i = 0; i < size; i++) {
                                //dbg(FLOODING_CHANNEL, "\t%i th Packet in the list\n", i);
                                stored = call PackLogs.get(i);
                                if (stored.src == packet->src && stored.seq == packet->seq) {
                                        //dbg(FLOODING_CHANNEL, "\t%s\n", stored.payload);
                                        return 1;
                                }
                        }
                }
                return 0;
        }

        /*
███    ██ ███████ ██  ██████  ██   ██ ██████   ██████  ██████      ██████  ██ ███████  ██████  ██████  ██    ██ ███████ ██████  ██    ██
████   ██ ██      ██ ██       ██   ██ ██   ██ ██    ██ ██   ██     ██   ██ ██ ██      ██      ██    ██ ██    ██ ██      ██   ██  ██  ██
██ ██  ██ █████   ██ ██   ███ ███████ ██████  ██    ██ ██████      ██   ██ ██ ███████ ██      ██    ██ ██    ██ █████   ██████    ████
██  ██ ██ ██      ██ ██    ██ ██   ██ ██   ██ ██    ██ ██   ██     ██   ██ ██      ██ ██      ██    ██  ██  ██  ██      ██   ██    ██
██   ████ ███████ ██  ██████  ██   ██ ██████   ██████  ██   ██     ██████  ██ ███████  ██████  ██████    ████   ███████ ██   ██    ██
*/

        void addNeighbor(uint8_t Neighbor) {
             if(Neighbor == 0)
               dbg(GENERAL_CHANNEL, "ZERO SOURCE WTFFFFFFFFFFFFFFFF");
             NeighborList[Neighbor] = MAX_NEIGHBOR_TTL;
        }

        void reduceNeighborsTTL() {
                int i;
                for (i = 0; i < NeighborListSize; i++) {

                        if(NeighborList[i] == 1) {

                                /* dbg (NEIGHBOR_CHANNEL, "\t Node %d Dropped from the Network \n", i); */

                                NeighborList[i] = 0;
                                routing[i][1] = 255;
                                routing[i][2] = 0;

                                // NeighborPing to neighbor we are dropppping
                                nodeSeq++;
                                makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 1, PROTOCOL_PING, nodeSeq, "Looking-4-Neighbors", PACKET_MAX_PAYLOAD_SIZE);
                                call Sender.send(sendPackage, (uint8_t) i);
                        }
                        if (NeighborList[i] > 1) {
                                NeighborList[i] -= 1;
                        } else {
                                /* dbg (NEIGHBOR_CHANNEL, "\t Node %d Dropped from the Network \n", i); */
                        }
                }
        }

        //  sends message to all known neighbors in neighbor list; if list is empty, forwards to everyone within range using AM_BROADCAST_ADDR.
	void relayToNeighbors(pack* recievedMsg) {
		/* if(recievedMsg->protocol == PROTOCOL_TCP) {
			dbg(GENERAL_CHANNEL, "RELAYING TCP PACKET(%d) TO  NEIGHBOR %d\n", recievedMsg->TTL, findNextHop(recievedMsg->dest));
		} */
                if(destIsNeighbor(recievedMsg)) {
                        /* dbg(NEIGHBOR_CHANNEL, "\tDeliver Message to Destination\n"); */
			if(recievedMsg->protocol == PROTOCOL_TCP) {
				dbg(GENERAL_CHANNEL, "RELAYING TCP PACKET(%d) TO Destination %d\n", recievedMsg->TTL, findNextHop(recievedMsg->dest));
			}
                        call Sender.send(sendPackage, recievedMsg->dest);
                } else {
                        //dbg(NEIGHBOR_CHANNEL, "\tTrynna Forward To Neighbors\n");
			if(recievedMsg->protocol == PROTOCOL_TCP) {
				dbg(GENERAL_CHANNEL, "RELAYING TCP PACKET(%d) TO NEIGHBOR %d\n", recievedMsg->TTL, findNextHop(recievedMsg->dest));
			}
                        call Sender.send(sendPackage, findNextHop(recievedMsg->dest));
                }
        }

        bool destIsNeighbor(pack* recievedMsg) {
                        if(NeighborList[recievedMsg->dest] > 0)
                            return 1;
                return 0;
        }

        //  Used for neighbor discovery, sends a Ping w/ TTL of 1 to AM_BROADCAST_ADDR.
        void scanNeighbors() {
                int i;
                if (!initialized) {
                        nodeSeq++;
                        makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 1, PROTOCOL_PING, nodeSeq, "Looking-4-Neighbors", PACKET_MAX_PAYLOAD_SIZE);
                        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                } else  {
                        reduceNeighborsTTL();
                }

        }

        /*
        ██████  ██    ██     ████████  █████  ██████  ██      ███████
        ██   ██ ██    ██        ██    ██   ██ ██   ██ ██      ██
        ██   ██ ██    ██        ██    ███████ ██████  ██      █████
        ██   ██  ██  ██         ██    ██   ██ ██   ██ ██      ██
        ██████    ████          ██    ██   ██ ██████  ███████ ███████
        */



        void initialize() {
                int i, j, neighbor;
                bool contains;
                dbg(ROUTING_CHANNEL, "\tMOTE(%d) Initializing DVR Table\n");

                // Setting all the Nodes in our pool/routing table to  MAX_HOP and setting their nextHop to our emlpty first cell
                for(i = 1; i < 20; i++) {
                         routing[i][0] = i;
                        routing[i][1] = 255;
                        routing[i][2] = 0;
                }

                // Setting the cost for SELF
                routing[TOS_NODE_ID][0] = TOS_NODE_ID;
                routing[TOS_NODE_ID][1] = 0;
                routing[TOS_NODE_ID][2] = TOS_NODE_ID;

                // Setting the cost to all my neighbors
                for(j = 1; j < NeighborListSize; j++) {
                         if(NeighborList[j] > 0)
                              insert(j, 1, j);
                }
                //dbg(GENERAL_CHANNEL, "\t~~~~~~~My, Mote %d's, Neighbors~~~~~~~initialize\n", TOS_NODE_ID);
                //signal CommandHandler.printNeighbors();
           }

        void insert(uint8_t dest, uint8_t cost, uint8_t nextHop) {
                //input data to a touple
                routing[dest][0] = dest;
                routing[dest][1] = cost;
                routing[dest][2] = nextHop;
        }

        void sendTableToNeighbors() {
                int i;
                for (i = 1; i < NeighborListSize; i++)
                    if(NeighborList[i] > 0)
                        splitHorizon((uint8_t)i); /* I am sending out counter i because that is the node ID and the actual value is the TTL */
        }

        bool mergeRoute(uint8_t* newRoute, uint8_t src){
             int node, cost, nextHop, i, j;
             bool alteredRoute = FALSE;

             // Using double forLoop instead of one, outer Iterated through routing, inner going through newRoute
            for (i = 0; i < 20; i++) {
                    for (j = 0; j < 7; j++) {
                            // Saving values for cleaner Code
                            node = *(newRoute + (j * 3));
                            cost = *(newRoute + (j * 3) + 1);
                            nextHop = *(newRoute + (j * 3) + 2);

                            if (node == routing[i][0]) {
                                    if ((cost+1) <= routing[i][1]) {
                                            /* dbg(GENERAL_CHANNEL, "\tRewriting route for node %d: %d < %d ---------------------\n", node, cost + 1, routing[i][1]); */
                                            routing[i][0] = node;
                                            routing[i][1] = cost + 1;
                                            routing[i][2] = src;

                                            alteredRoute = TRUE;
                                    }
                            }
                    }
            }

             // When inserting the partitioned DV tables to ours we want to iterate through all of the notes to compare them to our table
             /* for(i = 0; i < 20; i++) {
                     // Saving values for cleaner Code
                     node = *(newRoute + (i * 3));
                     cost = *(newRoute + (i * 3) + 1);
                     nextHop = *(newRoute + (i * 3) + 2);

                     //This should jump to the node we should be on, this doesnt work cause we are using i as the comparator for our incoming table
                     if (i != node && node != 0) {
                             j = node;
                     } else {
                             j = i;
                     }

                     // These are unset rows in out new table
                     if (node == routing[j][0] && nextHop !=0 && cost != 255) {
                             //dbg(GENERAL_CHANNEL, "\t Mote %d  Being Evaluated for Shorter Cost---------------------\n", node);
                             if ((cost + 1) < routing[j][1]) {
                                  dbg(GENERAL_CHANNEL, "\tRewriting route for node %d: %d < %d ---------------------\n", node, cost + 1, routing[j][1]);
                                     routing[j][0] = node;
                                     routing[j][1] = cost + 1;
                                     routing[j][2] = src;

                                     alteredRoute = TRUE;
                                     signal CommandHandler.printRouteTable();
                             }
                     }

                     // Making sure the cost to us is still 0
                     if (TOS_NODE_ID == routing[i][0]) {
                             routing[i][0] = TOS_NODE_ID;
                             routing[i][1] = 0;
                             routing[i][2] = TOS_NODE_ID;
                     }
             } */
             return alteredRoute;
        }


        // Used when sending DV Tables to Neighbors, nextHop is the Neighbor we are sending to
        void splitHorizon(uint8_t nextHop){
                int i, j;
                // Using two pointer to keep track of our first node
                uint8_t* startofPoison;
                uint8_t* poisonTbl = NULL;

                // Allocating size to store the item
                poisonTbl = malloc(sizeof(routing));
                startofPoison = malloc(sizeof(routing));

                // Copying routing table data bit-by-bit onto poisonTbl and memory location of the start of Neighbor
                memcpy(poisonTbl, &routing, sizeof(routing));
                startofPoison = poisonTbl;

                /* dbg(GENERAL_CHANNEL, "\t~~~~~~~My, Mote %d's, Neighbors~~~~~~~sH\n", TOS_NODE_ID);
                signal CommandHandler.printNeighbors(); */

                //Go through table once and Insert Poison aka MAX_HOP
                for(i = 0; i < 20; i++)
                        if (nextHop == i)
                                *(poisonTbl + (i*3) + 1) = 25;//Poison Reverse --  make the new path cost of where we sending to to MAX HOP NOT 255

             //Since Payload is too big we will send it in parts
             for(i = 0; i < 20; i++) { // Needs to start at 0 to be able to send the first table
                  //point to the next portion of the table and send to next node
                  if(i % 7 == 0){
                      nodeSeq++;
                      makePack(&sendPackage, TOS_NODE_ID, nextHop, 2, PROTOCOL_DV, nodeSeq, poisonTbl, sizeof(routing));
                      call Sender.send(sendPackage, nextHop);
                  }
                    poisonTbl += 3;
             }

        }

        uint8_t findNextHop(uint8_t dest) {
                int i;
                uint8_t nHop;
                for (i = 0; i <= poolSize; i++) {
                        if (routing[i][0] == dest) {
                                nHop = routing[i][2];
                                return nHop;
                        }
                }
        }



}
