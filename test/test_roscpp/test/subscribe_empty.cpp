/*
 * Copyright (c) 2008, Willow Garage, Inc.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of Willow Garage, Inc. nor the names of its
 *       contributors may be used to endorse or promote products derived from
 *       this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/* Author: Brian Gerkey */

/*
 * Subscribe to a topic, expecting to get a single message.
 */

#include <string>

#include <gtest/gtest.h>

#include <time.h>
#include <stdlib.h>

#include "ros/node.h"
#include <test_roscpp/TestEmpty.h>

int g_argc;
char** g_argv;

class PubSub : public testing::Test
{
  public:
    // A node is needed to make a service call
    ros::Node* n;
    test_roscpp::TestEmpty msg;
    bool success;
    bool failure;
    int msg_count;
    int msg_i;
    bool thread;
    ros::Duration dt;

    void MsgCallback()
    {
      if(failure || success)
        return;

      msg_i++;
      printf("received message %d\n", msg_i);
      if(msg_i == (msg_count-1))
      {
        success = true;
        puts("success");
      }
    }

  protected:
    PubSub() {}
    void SetUp()
    {
      ros::init(g_argc, g_argv);
      success = false;
      failure = false;

      msg_i = -1;
      ASSERT_TRUE(g_argc == 4);
      if(!strcmp(g_argv[1],"nothread"))
      {
        thread = false;
        n = new ros::Node("subscriber",ros::Node::DONT_START_SERVER_THREAD);
      }
      else
      {
        thread = true;
        n = new ros::Node("subscriber");
      }
      msg_count = atoi(g_argv[2]);
      dt.fromSec(atof(g_argv[3]));
    }
    void TearDown()
    {
      
      delete n;
    }
};

TEST_F(PubSub, pubSubNFast)
{
  ASSERT_TRUE(n->subscribe("test_roscpp/pubsub_test", msg, &PubSub::MsgCallback,
                           (PubSub*)this, msg_count));
  ros::Time t1(ros::Time::now()+dt);

  while(ros::Time::now() < t1 && !success)
  {
    // Sleep for 10ms
    if(thread)
    {
      struct timespec sleep_time = {0, 10000000};
      nanosleep(&sleep_time,NULL);
    }
    else
      n->tcprosServerUpdate();
  }

  if(success)
    SUCCEED();
  else
    FAIL();
}

int
main(int argc, char** argv)
{
  testing::InitGoogleTest(&argc, argv);
  g_argc = argc;
  g_argv = argv;
  return RUN_ALL_TESTS();
}
