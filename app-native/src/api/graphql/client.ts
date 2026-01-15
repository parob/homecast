import { ApolloClient, InMemoryCache, createHttpLink, from } from '@apollo/client/core';
import { setContext } from '@apollo/client/link/context';
import { onError } from '@apollo/client/link/error';
import { GRAPHQL_URL } from '@/constants/api';
import { useAuthStore } from '@/stores/authStore';

// HTTP link for GraphQL requests
const httpLink = createHttpLink({
  uri: GRAPHQL_URL,
});

// Auth link to add Bearer token to requests
const authLink = setContext(async (_, { headers }) => {
  const token = useAuthStore.getState().token;
  return {
    headers: {
      ...headers,
      authorization: token ? `Bearer ${token}` : '',
    },
  };
});

// Error handling link - using any to avoid Apollo v4 type issues
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const errorLink = onError((errorHandler: any) => {
  const { graphQLErrors, networkError, operation } = errorHandler;

  console.log(`[Apollo] Operation: ${operation?.operationName}, URL: ${GRAPHQL_URL}`);

  if (graphQLErrors) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    graphQLErrors.forEach((error: any) => {
      console.error(`[GraphQL error]: ${error.message}`, JSON.stringify(error));

      // Handle authentication errors
      if (error.message?.includes('Authentication required') || error.message?.includes('Invalid token')) {
        useAuthStore.getState().clearAuth();
      }
    });
  }

  if (networkError) {
    console.error(`[Network error]: ${JSON.stringify(networkError)}`);
    // Log more details about the network error
    const ne = networkError as any;
    if (ne.statusCode) console.error(`[Network error] Status: ${ne.statusCode}`);
    if (ne.result) console.error(`[Network error] Result: ${JSON.stringify(ne.result)}`);
    if (ne.bodyText) console.error(`[Network error] Body: ${ne.bodyText}`);
  }
});

// Apollo cache configuration
const cache = new InMemoryCache({
  typePolicies: {
    Query: {
      fields: {
        accessories: {
          merge(_existing = [], incoming) {
            return incoming;
          },
        },
      },
    },
    HomeKitAccessory: {
      keyFields: ['id'],
      fields: {
        services: {
          merge(_existing, incoming) {
            return incoming;
          },
        },
      },
    },
    HomeKitCharacteristic: {
      keyFields: ['id'],
      merge: true,
    },
    HomeKitHome: {
      keyFields: ['id'],
    },
    HomeKitRoom: {
      keyFields: ['id'],
    },
    HomeKitScene: {
      keyFields: ['id'],
    },
    Collection: {
      keyFields: ['id'],
    },
  },
});

// Create Apollo Client
export const apolloClient = new ApolloClient({
  link: from([errorLink, authLink, httpLink]),
  cache,
  defaultOptions: {
    watchQuery: {
      fetchPolicy: 'cache-and-network',
    },
    query: {
      fetchPolicy: 'cache-first',
    },
  },
});
