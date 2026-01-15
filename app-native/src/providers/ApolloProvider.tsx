import { ApolloProvider as BaseApolloProvider } from '@apollo/client/react';
import { apolloClient } from '@/api/graphql/client';

interface Props {
  children: React.ReactNode;
}

export function ApolloProvider({ children }: Props) {
  return <BaseApolloProvider client={apolloClient}>{children}</BaseApolloProvider>;
}
