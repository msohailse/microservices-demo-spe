# Project

**Google Online Boutique** (microservices-demo)  
**Fork:** [sohail0992/microservices-demo](https://github.com/sohail0992/microservices-demo)

![Architecture Diagram](./architecture.png)

## Services (12)
frontend, productcatalogservice, cartservice, checkoutservice, paymentservice, shippingservice, emailservice, currencyservice, recommendationservice, adservice, redis-cart, loadgenerator

## Fork Fix
Commit `ad87e17f`: relax health probes & CPU limits for minikube (4 CPU constraint)

## Metrics to Track
- P95/P99 latency
- Throughput
- Error rate
- CPU/Memory utilization
- Service call chains
