/*
  Presupuesto y alertas de coste
  ==============================

  El seguro que falta cuando se pasa a pago por uso. El credito de una cuenta
  gratuita dura 30 dias desde el alta, no hasta agotarse: el dia 31 las maquinas
  siguen encendidas y la factura empieza a ser tuya. Esto avisa antes.

  Dos tipos de umbral, y hacen falta los dos:

    Actual       salta cuando YA has gastado ese porcentaje. Llega tarde a
                 proposito, es la confirmacion
    Forecasted   salta cuando Azure proyecta que vas a llegar. Es el que de
                 verdad te da tiempo a reaccionar

  El presupuesto no corta nada: solo avisa. Para cortar esta teardown.sh.
*/

targetScope = 'subscription'

@description('Nombre del presupuesto.')
param nombre string = 'gdat-lab'

@description('Importe del presupuesto, en la moneda de facturacion de la suscripcion.')
param importe int = 200

@description('Correos que reciben los avisos. Sin al menos uno, esto no sirve de nada.')
@minLength(1)
param correos array

@description('Primer dia del periodo. Para un presupuesto mensual tiene que ser dia 1 y no puede estar en el pasado.')
param fechaInicio string = utcNow('yyyy-MM-01')

@description('Fin del periodo. Por defecto un ano, que sobra para un laboratorio.')
param fechaFin string = dateTimeAdd(utcNow('yyyy-MM-01'), 'P1Y', 'yyyy-MM-01')

resource presupuesto 'Microsoft.Consumption/budgets@2023-05-01' = {
  name: nombre
  properties: {
    category: 'Cost'
    amount: importe
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: fechaInicio
      endDate: fechaFin
    }
    notifications: {
      // Proyeccion al 80%: el aviso util, el que llega con margen.
      proyectado80: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 80
        thresholdType: 'Forecasted'
        contactEmails: correos
        locale: 'es-es'
      }
      real50: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: correos
        locale: 'es-es'
      }
      real80: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: correos
        locale: 'es-es'
      }
      // Al 100% ya no es un aviso, es "borra el laboratorio".
      real100: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: correos
        locale: 'es-es'
      }
    }
  }
}

output nombrePresupuesto string = presupuesto.name
output importe int = importe
