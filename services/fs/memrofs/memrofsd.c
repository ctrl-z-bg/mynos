/*
  MyNOS
  Copyright (C) 2002
  MyNOS team (http://sourceforge.net/projects/mynos/)

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
*/

#include <mynos.h>
#include <sys/types.h>
#include <unistd.h>
#include "memrofs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char * MAGIC = ".RAMDISK";

filedescriptor_t filedesc[MAXOPENFILES];
fileentry_t * filesystem;
char *ramdisk;

#define MIN(a, b) (((a)<(b))?(a):(b))

int isBusy(filedescriptor_t fdscr) {
  return(fdscr.pid);
}

void memrofs_open(pid_t client, char *fname) {
  int curr = 0;
  int found = 0;
  int fd = 3;
  open_response_t response;

  do {
    if ( !strncmp(filesystem[curr].filename, fname, FILENAMEMAXLEN) ) {
      found = 1;
      while ( isBusy(filedesc[fd]) && (fd < MAXOPENFILES) ) fd++;
      filedesc[fd].currpos = ramdisk + (int) filesystem[curr].start;
      filedesc[fd].fileidx = curr;
      filedesc[fd].pid = client;
    }
    curr++;
  } while ( (!found) && (curr<MAXFILES) );

  if ( curr >= MAXFILES ) { // file not found
    response.fd = -1;
    response.status = STATUS_NOT_FOUND;
  } else if ( fd >= MAXOPENFILES ) { // too many open files
    response.fd = -1;
    response.status = STATUS_TOO_MANY;
  } else { // OK
    response.fd = fd;
    response.status = STATUS_OK;
  }  
  if ( mynos_send(client, &response, 
		  sizeof(response), 0) < 0 )
    // error responding, close the file (if it was open)
    if ( response.status == STATUS_OK ) {
      filedesc[response.fd].pid = 0; // "close" the file
    }
}

void memrofs_close(pid_t client, int fd) {
  status_t status;
  if ( fd > MAXOPENFILES ) 
    status = STATUS_TOO_MANY;
  else if ( !(filedesc[fd].pid) )
    status = STATUS_NOT_OPEN;
  else if ( filedesc[fd].pid != client ) // not owner
    status = STATUS_PERMISSION_DENIED;
  else { // ok, close
    filedesc[fd].pid = 0;
    status = STATUS_OK;
  }
  if ( mynos_send(client, &status, 
		  sizeof(status_t), 0) < 0 ) {};
}

void memrofs_read(pid_t client, int fd, size_t size) {
  read_response_t response;

  response.rd = 0;
  if ( fd > MAXOPENFILES )
    response.status = STATUS_TOO_MANY;
  else if ( filedesc[fd].pid != client )
    response.status = STATUS_PERMISSION_DENIED;
  else { // actually read
    fileentry_t *fe = &filesystem[filedesc[fd].fileidx];
    response.rd = MIN(fe->size - (filedesc[fd].currpos - fe->start), size);
    response.status = STATUS_OK;
  }
  if ( mynos_send(client, &response,
		  sizeof(response), 
		  MYNOS_IPC_NONBLOCK) < 0 ) {
    // error, nothing to do
  } else {
    if ( (response.status == STATUS_OK) &&
	 (mynos_send(client, filedesc[fd].currpos, 
		     response.rd, 0) < 0) ) {
      // error, nothing to do
    } else {
      filedesc[fd].currpos += response.rd; // advance the pointer
    }
  }
}

void process_request(pid_t client, request_t request) {
  switch ( request.type ) {
  case OPEN:
    memrofs_open(client, request.data.fname);
    break;
  case CLOSE:
    memrofs_close(client, request.data.fd);
    break;
  case READ:
    memrofs_read(client, request.data.read_data.fd,
		 request.data.read_data.to_read);
    break;
  case LSEEK:
    break;
    // default:
    // something (signal error?)
  }

}

int main() {
  request_t request;
  int port;
  int channel;
  mynos_msg_t * msg;

  {
    int i;
    for (i = 0; i < 10000; i++);
  }

  port = mynos_registryRegister("memrofs");
  printf("memrofs service port: %d\n", port);

#if 0
  if ( mynos_recv(0 /* kernel! */, &ramdisk,
		  sizeof(char *), 0) < 0 ) {
    puts("Could not receive ramdisk pointer.");
    exit(-1);
  }
#else
  ramdisk = (char*)0x40400000;
#endif

  filesystem = (fileentry_t *)(ramdisk + strlen(MAGIC));
#define TEST
#ifdef TEST
  if ( fork() ) {
    //puts("father.");
    // father
  } else {
    // child
    char mybuf[1000];
    request_t request;
    open_response_t open_response;
    read_response_t read_response;
    int i;
    /* wait a bit to let the father's init */
    for (i = 0; i < 100000; i++);

    channel = mynos_connectToPort(port);

    //puts("child.");
    request.type = OPEN;
    strcpy(request.data.fname, "AUTOEXEC.BAT");
    //puts("prereq");
    puts("Opening a text file...");
    mynos_send(channel, &request, sizeof(request_t),
	       MYNOS_IPC_NONBLOCK);
    //puts("req1");
    mynos_recv(channel, &msg, 0, 0);
    memcpy(&open_response, msg->start, sizeof(open_response_t));
    mynos_freeMsg(&msg);
    if ( open_response.status != STATUS_OK ) {
      puts("Open failed");
      exit(-1);
    }
    //puts("resp1");
    mynos_freeChannel(channel);
    channel = mynos_connectToPort(port);
    puts("Reading the file content...");
    request.type = READ;
    request.data.read_data.fd = open_response.fd;
    request.data.read_data.to_read = 100;
    mynos_send(channel, &request, sizeof(request_t),
	       MYNOS_IPC_NONBLOCK);
    //puts("req2");
    if ( mynos_recv(channel, &msg, 0, 0) < 0 )
      puts("errore 1");
    //puts("resp2a");
    memcpy(&read_response, msg->start, sizeof(read_response_t));
    mynos_freeMsg(&msg);
    mynos_recv(channel, &msg, 0, 0);
    memcpy(mybuf, msg->start, 100);
    mynos_freeMsg(&msg);
    if ( read_response.rd == 0 )
      if ( read_response.status != STATUS_OK )
	puts("Some error.");
      else
	puts("EOF");
    else {
      mybuf[read_response.rd] = 0;
      puts("Show the content:");
      puts(mybuf);
    }
    
    exit(0);
  }
#endif /* TEST */

  while ( 1 ) {
    if ((channel = mynos_listenPort(port)) < 0) {
      puts("Error receiving request");
      exit(-1);
    }
    mynos_recv(channel, &msg, 0, 0);
    memcpy(&request, msg->start, sizeof(request_t));
    mynos_freeMsg(&msg);
    /* reply on the channel the request came from (sender was never set) */
    process_request(channel, request);
    mynos_freeChannel(channel);
  }

  return 0;
}
