# homelab-infra
This is a mix of a terraform project and a flux repo. It is not designed for reuse, it is designed to work, and to keep all of my infra-related stuff in one place.

There's two clusters to start with: 

- **critical**: Runs all the stuff that absolutely _must_ stay up, or I stop being able to maintain stuff. Git repos, ci/cd, MAAS, and so on.
- **main**: Runs everything else. Any services here can go down for a day or two without me caring too much.

# Why should you not attempt to do things my way?

I embrace the chicken-and-egg problem with open arms. You probably won't be able to just bootstrap this stuff directly.

I start with a raspberry pi running a dev instance of MAAS. Then use that to deploy the "critical" cluster. This includes setting up another MAAS install. After the critical cluster is deployed, I switch over to the critical cluster's copy of MAAS, and deploy the main cluster.

The end goal is to be able to manage both clusters with the instance of MAAS that is running on the critical cluster. Meaning that if all the nodes in the critical cluster lose their drives at the same time, I'm going to have some work in front of me.

This would be easier if I set up one computer manually with MAAS, and then added controllers to it to build out my critical cluster. But, that's not how I'm doing things.
