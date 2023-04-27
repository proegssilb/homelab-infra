# homelab-infra
This is a mix of a terraform project and a flux repo. It is not designed for reuse, it is designed to work, and to keep all of my infra-related stuff in one place.

There's two clusters to start with: 

- **critical**: Runs all the stuff that absolutely _must_ stay up, or I stop being able to maintain stuff. Git repos, ci/cd, MAAS, and so on.
- **main**: Runs everything else. Any services here can go down for a day or two without me caring too much.

# Why should you not attempt to do things my way?

The end goal is to be able to manage both clusters with the instance of MAAS that is running on the critical cluster. While there will be enough in here to bootstrap the setup from scratch, most people will not have the node count to do the madness I'm doing. And if they do have the nodes, they won't be interested in some of the constraints I place on myself, either for the sake of using MAAS to handle managing OSes, or for making sure hardware is disposable.

My desired setup is a chicken-and-egg problem centering on MAAS, solved by a masterless provisioning tool. If MAAS is responsible for provisioning the servers MAAS runs on, but it needs a server to start with, you clearly need something else to get that first server off the ground. This chicken-and-egg problem is not at all necessary for homelabs.

There are plenty of easier ways to do what I'm doing. You should do it one of the easier ways. Here's some that I've found:
- [Onedr0p's flux template](https://github.com/onedr0p/flux-cluster-template).
- [Traefik Turkey](https://github.com/traefikturkey/onramp), maintained by members of [TechnoTim](https://www.technotim.live/)'s community
