import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';

import { logError } from './errors';

type AsyncState<T> = {
  data: T | undefined;
  error: unknown;
  loading: boolean;
  /** Vuelve a pedir los datos (para "Reintentar" y pull-to-refresh) */
  reload: () => Promise<void>;
};

type Settled<T> = { key: string; data?: T; error: unknown };

/**
 * Carga datos con estados de loading / error / reintento.
 * `fn` se vuelve a ejecutar cuando cambian `deps` (valores simples: strings, números, booleanos).
 * Mientras cambian los deps no se muestran datos viejos de otra consulta.
 */
export function useAsync<T>(fn: () => Promise<T>, deps: unknown[], enabled = true): AsyncState<T> {
  const key = JSON.stringify(deps);
  const [settled, setSettled] = useState<Settled<T> | null>(null);
  const [reloading, setReloading] = useState(false);
  const fnRef = useRef(fn);
  const callId = useRef(0);

  useLayoutEffect(() => {
    fnRef.current = fn;
  });

  const execute = useCallback(async (forKey: string) => {
    const id = ++callId.current;
    try {
      const data = await fnRef.current();
      if (id === callId.current) setSettled({ key: forKey, data, error: null });
    } catch (e) {
      logError('useAsync', e);
      if (id === callId.current) setSettled((prev) => ({ key: forKey, data: prev?.key === forKey ? prev.data : undefined, error: e }));
    }
  }, []);

  useEffect(() => {
    if (enabled) void execute(key);
  }, [enabled, key, execute]);

  const reload = useCallback(async () => {
    setReloading(true);
    try {
      await execute(key);
    } finally {
      setReloading(false);
    }
  }, [execute, key]);

  const current = settled?.key === key ? settled : null;
  return {
    data: current?.data,
    error: current?.error ?? null,
    loading: enabled && (!current || reloading),
    reload,
  };
}
