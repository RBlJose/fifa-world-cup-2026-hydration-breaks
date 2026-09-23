# Análisis del Impacto de la Pausa de Hidratación
## FIFA World Cup 2026 — Documento de hallazgos

*Análisis elaborado combinando la observación directa del analista sobre el dashboard con el respaldo cuantitativo de los datos agregados.*

---

## 1. Contexto del torneo

La FIFA World Cup 2026 se disputó entre el **11 de junio y el 19 de julio de 2026**, con:

- **48 equipos** participantes
- **104 partidos** jugados
- **16 estadios** en **3 países sede** (Canadá, Estados Unidos y México)
- **207 pausas de hidratación** registradas en total

De estos 207 registros, se identificó que **hubo al menos un partido sin pausa de hidratación**, atribuible a condiciones climáticas que no alcanzaron el umbral que activa el protocolo — es decir, la ausencia de pausa en ese caso no es un vacío de datos, sino la aplicación correcta de la regla cuando no se cumplen las condiciones de calor/humedad requeridas.

**Nota metodológica importante:** al haber solo 3 países sede, la gran mayoría de los 104 partidos se disputaron entre selecciones donde ninguna jugaba "en casa". Las etiquetas **Local/Visitante** que aparecen en el dashboard deben leerse, en la mayoría de los casos, como una convención de datos (Equipo A / Equipo B) y no como una ventaja competitiva real de jugar en su propio país. Esta distinción solo tiene sentido real de "ventaja de local" en los partidos donde efectivamente participó Canadá, Estados Unidos o México como anfitrión.

---

## 2. ¿La pausa enfría o activa el partido? — Depende del nivel de presión

### 2.1 A nivel agregado del torneo (todos los partidos)

Tomando el total de eventos registrados en la ventana de 10 minutos antes/después de cada pausa:

| Evento | Antes de la pausa | Después de la pausa | Variación |
|---|---|---|---|
| Faltas | 417 | 505 | **+21.1%** |
| Tiros | (base) | +12 tiros | incremento neto positivo |

**A nivel global, la intensidad del partido aumenta después de la pausa**, no disminuye. Esto respalda la hipótesis de que, en promedio, los cuerpos técnicos usan la pausa para reorganizar la táctica y salir con mayor intensidad hacia el objetivo de ganar el partido.

Este patrón se mantiene consistente en las **fases de clasificación (Jornadas 1, 2 y 3), Dieciseisavos, Octavos, Cuartos y Semifinales**: en todas ellas, faltas y tiros post-pausa superan a los de pre-pausa, funcionando como un indicador razonable de mayor intensidad de juego tras la reanudación.

### 2.2 La excepción: los dos partidos de mayor presión del torneo

Al analizar de forma individual los dos partidos más importantes del calendario — **la Final (España 1-0 Argentina, tras tiempo extra)** y el **partido por el Tercer Puesto (Francia 6-4 Inglaterra)** — el patrón se invierte por completo.

**Final — España vs Argentina:**

| Tramo | Eventos Pre | Eventos Post | Impacto Agregado |
|---|---|---|---|
| 1er tiempo (pausa min. 25-27) | 9 | 9 | **0** (neutro) |
| 2do tiempo (pausa min. 67-70) | 10 | 6 | **-4** |

En el primer tiempo el efecto es neutro — el equipo dominante reduce ligeramente su ritmo natural de cansancio acumulado, algo esperable y hasta positivo desde el punto de vista fisiológico. Pero en el segundo tiempo, específicamente en el tramo de los 70-75 minutos (justo tras la pausa), **España tuvo una caída marcada de intensidad de juego**, que solo se fue recuperando gradualmente con el paso de los minutos, sin volver de inmediato al nivel previo a la pausa.

**Tercer Puesto — Francia vs Inglaterra:** el patrón observado por el analista es de un **descenso continuo y gradual** de intensidad acercándose a la pausa (no un quiebre puntual), con una recuperación parcial posterior que no llega a igualar el nivel previo (según las cifras registradas por el analista: faltas ≈14 antes vs ≈11 después, tiros ≈10 antes vs ≈3 después, con más goles generados antes de la pausa que después en ese partido).

**Interpretación:** cuando el partido ya se juega a máxima intensidad (una final, una definición de tercer puesto), la pausa no tiene margen para "activar más" al equipo — más bien corta una inercia que ya estaba al límite, y el costo de recuperar ese ritmo es mayor que el beneficio fisiológico de la hidratación. En cambio, en partidos de fase de grupos o rondas tempranas, donde la intensidad de partida es más moderada, la pausa sí funciona como punto de ajuste táctico que **incrementa** el ritmo de juego.

Esta es la conclusión central del análisis: **el efecto de la pausa de hidratación no es uniforme — depende del nivel de presión competitiva del partido**, y en los partidos de mayor peso, el efecto tiende a ser negativo para el equipo que dominaba antes del corte.

---

## 3. Patrón "montaña rusa" a nivel de equipo dominante

Revisando el Momentum Chart de partidos individuales:

- **Ecuador vs México:** el equipo dominante (México, como local) muestra una caída de intensidad justo al aproximarse cada pausa, y una recuperación justo después — en ambos tiempos, un patrón de sube y baja marcado. Ecuador, en cambio, se mantiene neutro durante todo el partido, sin ese patrón cíclico, coherente con que tampoco generó tanto volumen de juego en general.

- **Francia vs Inglaterra:** no se observa un quiebre puntual justo en la pausa, sino un desgaste progresivo y continuo del equipo que dominaba, con recuperación parcial (no completa) tras la pausa.

- **Final España vs Argentina:** el mismo patrón de caída de intensidad del equipo dominante justo al llegar a la pausa se repite, siendo más pronunciado en el segundo tiempo que en el primero.

**Conclusión de este apartado:** el patrón de "bajón justo antes/durante la pausa y recuperación después" aparece de forma recurrente en el equipo que domina el partido, pero **su magnitud y velocidad de recuperación varían** — es más brusco y de recuperación lenta en partidos de alta exigencia (Final), y más gradual/sostenido en otros (Tercer Puesto), lo que refuerza la idea de que el contexto competitivo modula el efecto observado.

---

## 4. ¿Las pausas generan goles?

| Ventana | % Gol Post Pausa (observado) | Tasa Esperada por Azar | Diferencia |
|---|---|---|---|
| 5 min | **19.23%** | 15.41% | **+3.82 pp** |
| 10 min | **25.96%** | 28.44% | -2.48 pp |
| 15 min | **35.58%** | 39.46% | -3.88 pp |

**Solo en la ventana de 5 minutos** lo observado supera claramente a lo esperado por azar. En las ventanas de 10 y 15 minutos, el efecto se revierte: lo observado queda por debajo de la línea base — es decir, el "exceso" de goles atribuible a la pausa se concentra únicamente en los primeros minutos tras la reanudación y no se sostiene en ventanas más amplias.

Interpolando visualmente entre las dos curvas (5→15 min), el punto de cruce donde el porcentaje observado y la tasa esperada se igualarían estaría aproximadamente en el **minuto 7** post-pausa — esta es una estimación visual del analista, no un cálculo estadístico exacto, y se presenta como tal.

**Quién anota más tras la pausa:** de 37 pausas seguidas de gol (ventana 15 min), el equipo identificado como "local" anotó el **64.86%** (24 goles) y el "visitante" el **35.14%** (13 goles) — una ventaja de **+14.86 puntos** sobre el 50/50 esperado si no hubiera ningún sesgo.

**Limitación metodológica clave (ya señalada en la sección 1):** dado que la mayoría de los partidos se jugaron entre selecciones sin relación real de local/visitante, este 64.86% **no debe interpretarse como "ventaja de jugar en casa"** en el sentido tradicional del fútbol. Una forma más rigurosa de leer este resultado —y una línea de trabajo pendiente sugerida— sería volver al Momentum Chart de cada una de esas 37 pausas y verificar cuál de los dos equipos (independientemente de la etiqueta local/visitante) mostraba mayor dominancia/intensidad justo antes de la pausa, para confirmar si el equipo que ya dominaba el juego es también el que más se benefició de anotar después — lo cual sería una explicación más sólida que atribuirlo a la etiqueta de "local".

---

## 5. Fase de grupos vs eliminatoria, y clima — hallazgo nulo, pero válido

La duración promedio de pausa (Eliminatoria: 2.00 · Fase de Grupos: 1.99) y la comparación por clima (Ciudad fría: 2.8 min · Ciudad cálida: 2.8 min) no muestran diferencias relevantes.

Esto **no es un dato irrelevante, sino una confirmación de que el protocolo de pausa está reglado y estandarizado**: la duración depende de una regla fija (~3 minutos) con margen de ajuste del árbitro según circunstancias puntuales del momento (sustituciones en curso, atención médica), no del contexto competitivo ni climático de cada partido. De la misma forma, la cantidad de pausas por partido (~2 en promedio) responde al cumplimiento de un umbral reglamentario, no a una variable orgánica del juego. Por eso esta comparación no aporta un patrón de comportamiento futbolístico — confirma la consistencia operativa del protocolo, que es un hallazgo distinto (y también válido) al que se buscaba originalmente.

---

## 6. Ficha de partido — rol exploratorio, no analítico adicional

La página de Ficha de Partido no genera un hallazgo nuevo por sí misma: funciona como una herramienta de exploración caso por caso (por ejemplo, revisar el partido de Cabo Verde vs Argentina, o cualquier partido de interés personal) para inspeccionar tarjetas, situaciones de gol y eventos — es, en esencia, un resumen de partido interactivo, útil como herramienta de consulta más que como fuente de una conclusión agregada.

---

## 7. Reflexión final — ¿vale la pena la pausa de hidratación?

La hipótesis inicial del proyecto era que la pausa de hidratación **beneficia** la dinámica del juego (mayor intensidad, más ocasiones de gol). Los datos matizan esa hipótesis:

- **A nivel global y en partidos de presión media/baja**, sí hay más intensidad después de la pausa — la hipótesis se cumple.
- **En los partidos de mayor exigencia (Final, Tercer Puesto)**, ocurre lo contrario: el equipo dominante pierde ritmo tras la pausa y tarda en recuperarlo.
- **El efecto sobre la probabilidad de gol** es real pero se concentra únicamente en los primeros ~5-7 minutos tras la reanudación; no se sostiene en ventanas más amplias.

Esto abre una pregunta legítima para el cierre del proyecto: la pausa de hidratación, tal como está reglamentada, **parece tener una motivación primariamente operativa/comercial** (pausas publicitarias, gestión del calor en transmisión) más que estar optimizada para preservar la calidad del espectáculo en los partidos de mayor intensidad — sin que esto reste validez a su función de proteger la salud de los jugadores en condiciones de calor extremo, que es su justificación oficial.

**Línea de investigación futura (fuera del alcance de este proyecto):** un diseño tipo A/B comparando este torneo contra Mundiales sin pausa obligatoria (2022, donde no era un protocolo formal) permitiría aislar mejor el efecto causal de la regla — se documenta aquí como posible extensión, no como análisis realizado.

---

## 8. Resumen ejecutivo (una línea por hallazgo)

1. El torneo tuvo 207 pausas en 104 partidos, con una excepción justificada por clima.
2. Las etiquetas local/visitante no representan ventaja real de sede en la mayoría de los partidos.
3. A nivel agregado, la intensidad **aumenta** tras la pausa (+21.1% en faltas); en los partidos de mayor presión (Final, Tercer Puesto), **disminuye**.
4. El equipo dominante muestra un patrón recurrente de caída de ritmo justo antes/durante la pausa, con recuperación variable según el partido.
5. El exceso de probabilidad de gol atribuible a la pausa se concentra en los primeros 5-7 minutos y no se sostiene en ventanas más amplias.
6. La ventaja de "65% a favor del local" en goles post-pausa requiere verificación cruzada con el momentum previo, no debe leerse como home advantage tradicional.
7. Fase y clima no afectan la duración/frecuencia de pausa — el protocolo se aplica de forma estandarizada.
8. La pausa parece cumplir mejor su función en partidos de presión media/baja que en los de mayor exigencia competitiva.

---

*Documento elaborado para el portafolio de analítica deportiva — FIFA World Cup 2026: Impacto de las Pausas de Hidratación. Los porcentajes y cifras agregadas provienen de los datos del Data Warehouse; las interpretaciones de patrones individuales de partido (Ecuador vs México, Francia vs Inglaterra, Final) reflejan la observación directa del analista sobre el Momentum Chart.*
