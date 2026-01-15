import { createContext, useContext, useEffect, useCallback, useMemo } from 'react';
import { useLazyQuery, useMutation, useApolloClient } from '@apollo/client/react';
import { useRouter, useSegments } from 'expo-router';
import { ME_QUERY } from '@/api/graphql/queries';
import { LOGIN_MUTATION, SIGNUP_MUTATION } from '@/api/graphql/mutations';
import { useAuthStore } from '@/stores/authStore';
import { webSocketClient } from '@/api/websocket/client';
import { useAccessoryStore } from '@/stores/accessoryStore';
import type { UserInfo, AuthResult } from '@/types/api';

interface AuthContextType {
  isLoading: boolean;
  isAuthenticated: boolean;
  userId: string | null;
  email: string | null;
  login: (email: string, password: string) => Promise<{ success: boolean; error?: string }>;
  signup: (
    email: string,
    password: string,
    name?: string
  ) => Promise<{ success: boolean; error?: string }>;
  logout: () => Promise<void>;
}

const AuthContext = createContext<AuthContextType | null>(null);

interface Props {
  children: React.ReactNode;
}

export function AuthProvider({ children }: Props) {
  const router = useRouter();
  const segments = useSegments();
  const client = useApolloClient();

  const { token, isAuthenticated, userId, email, isLoading, setAuth, clearAuth, setLoading } =
    useAuthStore();

  const [verifyMe] = useLazyQuery<{ me: UserInfo }>(ME_QUERY, { fetchPolicy: 'network-only' });
  const [loginMutation] = useMutation<{ login: AuthResult }>(LOGIN_MUTATION);
  const [signupMutation] = useMutation<{ signup: AuthResult }>(SIGNUP_MUTATION);

  // Verify token on mount
  useEffect(() => {
    const verifyToken = async () => {
      if (token) {
        try {
          const { data } = await verifyMe();
          if (data?.me) {
            // Token is valid, connect WebSocket
            webSocketClient.connect(token);
          } else {
            // Token invalid, clear auth
            clearAuth();
          }
        } catch {
          clearAuth();
        }
      }
      setLoading(false);
    };

    verifyToken();
  }, []);

  // Route protection
  useEffect(() => {
    if (isLoading) return;

    const inAuthGroup = segments[0] === '(auth)';

    if (!isAuthenticated && !inAuthGroup) {
      // Redirect to login if not authenticated
      router.replace('/login');
    } else if (isAuthenticated && inAuthGroup) {
      // Redirect to main app if authenticated and on auth screen
      router.replace('/');
    }
  }, [isAuthenticated, segments, isLoading]);

  const login = useCallback(
    async (loginEmail: string, password: string) => {
      try {
        const { data } = await loginMutation({
          variables: { email: loginEmail, password },
        });

        const result = data?.login;
        if (result?.success && result.token) {
          setAuth(result.token, result.userId!, result.email!);
          webSocketClient.connect(result.token);
          return { success: true };
        }

        return { success: false, error: result?.error || 'Login failed' };
      } catch (error: unknown) {
        // Show detailed error for debugging
        const err = error as Error & { networkError?: { statusCode?: number; result?: unknown; message?: string } };
        let errorMsg = 'Network error. ';
        if (err.networkError) {
          errorMsg += `Status: ${err.networkError.statusCode || 'unknown'}. `;
          if (err.networkError.result) {
            errorMsg += `Result: ${JSON.stringify(err.networkError.result)}. `;
          }
          if (err.networkError.message) {
            errorMsg += `Message: ${err.networkError.message}`;
          }
        } else if (err.message) {
          errorMsg += err.message;
        }
        return { success: false, error: errorMsg };
      }
    },
    [loginMutation, setAuth]
  );

  const signup = useCallback(
    async (signupEmail: string, password: string, name?: string) => {
      try {
        const { data } = await signupMutation({
          variables: { email: signupEmail, password, name },
        });

        const result = data?.signup;
        if (result?.success && result.token) {
          setAuth(result.token, result.userId!, result.email!);
          webSocketClient.connect(result.token);
          return { success: true };
        }

        return { success: false, error: result?.error || 'Signup failed' };
      } catch (error) {
        console.error('Signup error:', error);
        return { success: false, error: 'Network error. Please try again.' };
      }
    },
    [signupMutation, setAuth]
  );

  const logout = useCallback(async () => {
    webSocketClient.disconnect();
    await client.clearStore();
    useAccessoryStore.getState().clearAll();
    clearAuth();
  }, [client, clearAuth]);

  const value = useMemo(
    () => ({
      isLoading,
      isAuthenticated,
      userId,
      email,
      login,
      signup,
      logout,
    }),
    [isLoading, isAuthenticated, userId, email, login, signup, logout]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error('useAuth must be used within AuthProvider');
  }
  return context;
}
