"""
Consumidor: toma las lecturas de RabbitMQ y las guarda en PostgreSQL con el
usuario consumidor_iot (solo puede insertar lecturas). Cada 30 s refresca la
vista materializada mv_resumen_hora mediante la funcion refrescar_resumen().
"""
import json
import os
import time

import pika
import psycopg

CONNINFO = (f"host={os.getenv('DB_HOST', 'datos')} dbname=iotanalytics "
            f"user={os.getenv('DB_USER', 'consumidor_iot')} "
            f"password={os.environ['DB_PASSWORD']} sslmode=require")
REFRESCO = int(os.getenv("REFRESCO_SEG", "30"))

INSERTAR = """INSERT INTO lecturas (sensor_id, valor, medido_en)
              SELECT id, %s, %s FROM sensores WHERE codigo = %s"""


def conectar_bd():
    while True:
        try:
            return psycopg.connect(CONNINFO, autocommit=True)
        except psycopg.OperationalError:
            print("PostgreSQL no disponible, reintentando...")
            time.sleep(3)


def conectar_rabbit():
    params = pika.URLParameters(os.getenv("RABBIT_URL", "amqp://iot:iot123@mensajes:5672/"))
    while True:
        try:
            return pika.BlockingConnection(params)
        except pika.exceptions.AMQPConnectionError:
            print("RabbitMQ no disponible, reintentando...")
            time.sleep(3)


def main():
    bd = conectar_bd()
    print("Conectado a PostgreSQL con SSL:", bd.info.pgconn.ssl_in_use)
    con = conectar_rabbit()
    canal = con.channel()
    canal.queue_declare(queue="lecturas", durable=True)
    canal.basic_qos(prefetch_count=50)
    guardadas = 0

    def al_recibir(ch, metodo, _props, cuerpo):
        nonlocal guardadas
        lectura = json.loads(cuerpo)
        filas = bd.execute(INSERTAR, (lectura["valor"], lectura["medido_en"],
                                      lectura["sensor"])).rowcount
        if filas == 0:
            print(f"Sensor desconocido: {lectura['sensor']}")
        guardadas += filas
        ch.basic_ack(delivery_tag=metodo.delivery_tag)

    def refrescar():
        inicio = time.perf_counter()
        bd.execute("SELECT refrescar_resumen()")
        print(f"{guardadas} lecturas guardadas · mv_resumen_hora refrescada en "
              f"{(time.perf_counter() - inicio) * 1000:.0f} ms")
        con.call_later(REFRESCO, refrescar)

    con.call_later(REFRESCO, refrescar)
    canal.basic_consume(queue="lecturas", on_message_callback=al_recibir)
    print("Consumidor escuchando la cola 'lecturas'")
    canal.start_consuming()


if __name__ == "__main__":
    main()
