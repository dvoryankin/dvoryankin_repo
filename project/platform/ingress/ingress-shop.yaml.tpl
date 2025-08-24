apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  namespace: default
spec:
  ingressClassName: nginx
  rules:
  - host: ${SHOP_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 80
