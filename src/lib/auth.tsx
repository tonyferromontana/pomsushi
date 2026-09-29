import type { Session } from '@supabase/supabase-js';
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';

import { logError } from './errors';
import { isSupabaseConfigured, supabase } from './supabase';

type AuthState = {
  session: Session | null;
  userId: string | null;
  loading: boolean;
};

const AuthContext = createContext<AuthState>({ session: null, userId: null, loading: true });

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(isSupabaseConfigured);

  useEffect(() => {
    if (!isSupabaseConfigured) return;

    supabase.auth
      .getSession()
      .then(({ data, error }) => {
        if (error) logError('auth.getSession', error);
        setSession(data.session);
      })
      .finally(() => setLoading(false));

    const { data } = supabase.auth.onAuthStateChange((_event, next) => setSession(next));
    return () => data.subscription.unsubscribe();
  }, []);

  return (
    <AuthContext.Provider value={{ session, userId: session?.user.id ?? null, loading }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth(): AuthState {
  return useContext(AuthContext);
}
