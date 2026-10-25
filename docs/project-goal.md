# Project Goal

This is to give a high level overview to help inform desicions so they are working towards the correct objective. This file should not be edited by an agent unless explicitly asked by a human.

This is a planning app. What makes it different from the other planning apps that exist is that it is leans into high automation, very throughough goals and planning and high attention to detail when reporting. This app is for people that want to plan out their day at 15 minute intervals and know exactly what they were doing every second. Making plans that detailed can be exhausting and most people don't do it because it is too laborsome to make those kinds of plans. With this app hopefully that changes. It should be very easy to plan at a high grainularity and report exicution on that plan.

The user can build a goal tree for their life. It's impossible to plan out everything that you could possibly need to do, but hopefully as users use the app their vision for their tree will grow and change. High level goals are often quite abstract and somewhat philisophical and we hope to map them to very concrete goals that can be completed in a day. Automation and integration with external apps allow for easy reporting of various low level goals.

I included some screenshots of my figma goal board and how I used my toggle calendar. Those help represent the use case.

Here are some of my thoughts on how model should work:

### Goal
These sit in the goal menu. They make a tree. This was based on the realization that there isn't a difference between a subgoal and a plan.

### Task
A type of goal that is planned for specific calendar block smaller than a day. Once we get down small enough that we can schedule it the goal is concrete enough that we want to track it as a task. A task doesn't need to be assigned a time yet. That why we have the button to schedule them on the calendar.

### Event
These are visible on the calendar. If it's not visible on the calendar it's not an event. 

## Open Questions
Somethings I haven't quite figured out yet is how to deal with really long term plans aside from using the goal tree. Mostly relating how can we model a long term finacial plan in a way that is congruent with everything else.
